//! Thinning out old autosaves by a retention policy (`retention.rs`), only for Typewright's own plain linear commits.
use std::collections::{BTreeSet, HashMap, HashSet};

use anyhow::Result;
use futures::StreamExt as _;
use jj_lib::backend::CommitId;
use jj_lib::commit::Commit;
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::revset::RevsetExpression;
use pollster::FutureExt as _;

use crate::repo::{APP_TRAILER, Repo, display_description, first_parent_chain};
use crate::retention::{Item, Policy, keep};

/// Squashed descriptions keep at most this many distinct lines.
const MAX_LINES: usize = 20;

fn evaluate(repo: &ReadonlyRepo, expression: std::sync::Arc<jj_lib::revset::ResolvedRevsetExpression>) -> Result<HashSet<CommitId>> {
    let revset = expression.evaluate(repo)?;
    let mut stream = revset.stream();
    let mut out = HashSet::new();
    while let Some(id) = stream.next().block_on() {
        out.insert(id?);
    }
    Ok(out)
}

/// Commits squashing must leave alone: bookmarks, tags and remote bookmarks point at them, or they're ancestors of
/// tags or remote bookmarks (jj's default immutable heads).
fn protected(repo: &ReadonlyRepo) -> Result<(HashSet<CommitId>, HashSet<CommitId>)> {
    let view = repo.view();
    let mut targets: Vec<CommitId> = Vec::new();
    let mut immutable_heads: Vec<CommitId> = Vec::new();
    for (_, target) in view.local_bookmarks() {
        targets.extend(target.adds().flatten().cloned());
    }
    for (_, target) in view.local_tags() {
        targets.extend(target.adds().flatten().cloned());
        immutable_heads.extend(target.adds().flatten().cloned());
    }
    for (_, remote) in view.all_remote_bookmarks() {
        targets.extend(remote.target.adds().flatten().cloned());
        immutable_heads.extend(remote.target.adds().flatten().cloned());
    }
    let immutable = evaluate(repo, RevsetExpression::commits(immutable_heads).ancestors())?;
    Ok((targets.into_iter().collect(), immutable))
}

impl Repo {
    fn squashable(&self, repo: &ReadonlyRepo, commit: &Commit, targets: &HashSet<CommitId>, immutable: &HashSet<CommitId>) -> Result<bool> {
        if !commit.description().trim_end().ends_with(APP_TRAILER)
            || commit.parent_ids().len() != 1
            || commit.has_conflict()
            || targets.contains(commit.id())
            || immutable.contains(commit.id())
        {
            return Ok(false);
        }
        let divergent = repo
            .resolve_change_id(commit.change_id())
            .block_on()?
            .is_some_and(|t| t.visible_with_offsets().count() > 1);
        Ok(!divergent)
    }

    /// Applies `policy` to @'s first-parent chain: commits it doesn't keep are squashed into the next newer kept one,
    /// so every kept commit is still an exact snapshot. Only squashable runs (see `squashable`) are touched; the
    /// newest commit of each run is always kept, so nothing is squashed across a commit the user cares about. Trees
    /// never change, so other workspaces and descendants keep their content; the chain is rebuilt by hand to keep its
    /// timestamps. Returns (squashed, kept) counts over the chain.
    pub fn squash(&mut self, policy: &Policy) -> Result<(usize, usize)> {
        let repo = self.prepare()?;
        let name = self.workspace.workspace_name().to_owned();
        let wc = self.wc_commit(&repo)?;
        let mut chain = first_parent_chain(repo.as_ref(), &wc)?;
        chain.reverse();
        let (targets, immutable) = protected(&repo)?;
        let mut ok = Vec::with_capacity(chain.len());
        for commit in &chain {
            ok.push(self.squashable(&repo, commit, &targets, &immutable)?);
        }
        // Members before a group's last must have the next member as their only child.
        let ids: Vec<CommitId> = chain.iter().map(|c| c.id().clone()).collect();
        let mut child_counts: HashMap<CommitId, usize> = HashMap::new();
        for child in evaluate(&repo, RevsetExpression::commits(ids).children())? {
            for parent in repo.store().get_commit(&child)?.parent_ids() {
                *child_counts.entry(parent.clone()).or_default() += 1;
            }
        }
        let only_child: Vec<bool> =
            (0..chain.len()).map(|i| i + 1 < chain.len() && child_counts.get(chain[i].id()) == Some(&1)).collect();
        // Runs end where the next commit can't join; their newest commit is pinned like anything unsquashable.
        let linked = |i: usize| i + 1 < chain.len() && ok[i] && ok[i + 1] && only_child[i];
        let items: Vec<Item> = (0..chain.len())
            .rev()
            .map(|i| {
                let time = &chain[i].author().timestamp;
                Item { millis: time.timestamp.0, offset: time.tz_offset, pinned: !ok[i] || !linked(i) }
            })
            .collect();
        let mut kept = keep(&items, policy);
        kept.reverse();
        let mut groups = Vec::new();
        let mut i = 0;
        while i < chain.len() {
            if kept[i] {
                i += 1;
                continue;
            }
            // Unkept commits are linked, so the run reaches a kept commit before it ends.
            let mut j = i;
            while !kept[j] {
                j += 1;
            }
            groups.push(i..j + 1);
            i = j + 1;
        }
        let squashed: usize = groups.iter().map(|g| g.len() - 1).sum();
        let remaining = chain.len() - squashed;
        if groups.is_empty() {
            return Ok((0, remaining));
        }

        let mut tx = repo.start_transaction();
        let mut_repo = tx.repo_mut();
        let mut parent: Option<CommitId> = None;
        let mut i = 0;
        while i < chain.len() {
            let (commit, description) = match groups.iter().find(|g| g.start == i) {
                Some(group) => {
                    let members = &chain[group.clone()];
                    for c in &members[..members.len() - 1] {
                        mut_repo.record_abandoned_commit(c);
                    }
                    i = group.end;
                    let mut seen = BTreeSet::new();
                    let descriptions: Vec<String> = members.iter().map(|c| display_description(c.description())).collect();
                    let lines: Vec<&str> = descriptions
                        .iter()
                        .flat_map(|d| d.lines())
                        .filter(|l| !l.trim().is_empty() && seen.insert(*l))
                        .take(MAX_LINES)
                        .collect();
                    let first_parent = members[0].parent_ids()[0].clone();
                    (members.last().unwrap(), Some((lines.join("\n"), first_parent)))
                }
                None => {
                    i += 1;
                    (&chain[i - 1], None)
                }
            };
            let mut parents = commit.parent_ids().to_vec();
            if let Some((_, first_parent)) = &description {
                parents[0] = first_parent.clone();
            }
            if let Some(p) = &parent {
                parents[0] = p.clone();
            }
            if description.is_none() && parents == commit.parent_ids() {
                parent = Some(commit.id().clone());
                continue;
            }
            let mut builder = mut_repo
                .rewrite_commit(commit)
                .set_parents(parents)
                .set_author(commit.author().clone())
                .set_committer(commit.committer().clone());
            if let Some((text, _)) = description {
                builder = builder.set_description(format!("{text}\n\n{APP_TRAILER}\n"));
            }
            parent = Some(builder.write().block_on()?.id().clone());
        }
        if let Some(parent) = parent
            && wc.parent_ids()[0] != parent
        {
            let mut parents = wc.parent_ids().to_vec();
            parents[0] = parent;
            let new_wc = mut_repo
                .rewrite_commit(&wc)
                .set_parents(parents)
                .set_author(wc.author().clone())
                .set_committer(wc.committer().clone())
                .write()
                .block_on()?;
            mut_repo.set_wc_commit(name, new_wc.id().clone())?;
        }
        // Side branches off rewritten commits; their trees stay the same since no tree changed.
        mut_repo.rebase_descendants().block_on()?;
        #[cfg(target_os = "macos")]
        let _git_lock = self.export_git(&mut tx)?;
        let new_repo = tx.commit("typewright: squash history").block_on()?;
        let new_wc = self.wc_commit(&new_repo)?;
        let mut locked = self.workspace.start_working_copy_mutation().block_on()?;
        locked.locked_wc().reset(&new_wc).block_on()?;
        locked.finish(new_repo.op_id().clone()).block_on()?;
        self.after_transaction(&repo, &new_repo)?;
        Ok((squashed, remaining))
    }
}
