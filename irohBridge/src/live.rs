//! Live editing of one file on several devices at once.
//!
//! Each device with a file open keeps it as a yrs text and sends every keystroke to the space's
//! gossip topic, so edits arrive within a network round trip and merge without conflicts. Sessions
//! start from each device's text; when two meet, the older session wins and the newer device adopts
//! it, merging its own edits back in from Swift. Remote changes queue up until Swift asks for them in
//! `sync`, which also takes Swift's current text, so both sides always change the same text.

use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use bytes::Bytes;
use iroh::EndpointId;
use iroh_gossip::{TopicId, api::Event};
use n0_future::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio::{sync::mpsc, task::JoinHandle};
use yrs::{
    Any, Doc, GetString, Observable, OffsetKind, Options, Out, ReadTxn, StateVector, StickyIndex, Text,
    TextRef, Transact, Update, UndoManager,
    Assoc, IndexedSequence,
    types::Delta,
    undo,
    updates::{decoder::Decode, encoder::Encode},
};

use crate::{Inner, derive};

/// When two sessions meet, the one created first wins; the random part breaks ties.
type SessionKey = (u64, u64);

const HEARTBEAT: Duration = Duration::from_secs(2);
/// A device that sent nothing for this long has closed the file or gone away.
const PEER_TIMEOUT: Duration = Duration::from_secs(8);
const REMOTE: &str = "remote";

#[derive(Serialize, Deserialize)]
struct Envelope {
    from: String,
    /// Gossip drops repeated messages, so identical ones need to differ.
    nonce: u64,
    path: String,
    body: Body,
}

#[derive(Serialize, Deserialize)]
enum Body {
    /// The whole document; `reply` asks devices in the same or an older session to answer with theirs.
    State { session: SessionKey, update: Vec<u8>, reply: bool },
    Update { session: SessionKey, update: Vec<u8> },
    Cursor { session: SessionKey, name: String, anchor: Vec<u8>, head: Vec<u8> },
    /// Sent regularly; devices missing something answer with an `Update`.
    Sync { session: SessionKey, state: Vec<u8> },
    Leave,
}

/// The space's gossip topic: messages go out in order through one task.
pub(crate) struct Topic {
    id: TopicId,
    outbox: mpsc::UnboundedSender<Bytes>,
    sender: iroh_gossip::api::GossipSender,
    tasks: Vec<JoinHandle<()>>,
}

impl Drop for Topic {
    fn drop(&mut self) {
        self.tasks.iter().for_each(JoinHandle::abort);
    }
}

struct Peer {
    name: String,
    anchor: Option<StickyIndex>,
    head: Option<StickyIndex>,
    seen: Instant,
}

enum Pending {
    Update(Vec<u8>),
    Adopt(Vec<u8>),
}

pub(crate) struct Session {
    key: SessionKey,
    doc: Doc,
    text: TextRef,
    undo: UndoManager,
    /// Remote and undo changes as edits in UTF-16 offsets, each relative to the text after the previous one.
    edits: Arc<Mutex<Vec<(u32, u32, String)>>>,
    /// The text the session started from, to merge into when adopting another session.
    base: String,
    name: String,
    pending: Vec<Pending>,
    /// An older session's state waits for Swift; until then nothing goes out under its key.
    adopting: bool,
    peers: HashMap<String, Peer>,
    selection: Option<(u32, u32)>,
    /// Set once Swift was told about changes, until it syncs.
    notified: bool,
}

impl Session {
    fn new(key: SessionKey, name: String, base: String) -> Self {
        let doc = Doc::with_options(Options { offset_kind: OffsetKind::Utf16, ..Options::default() });
        let text = doc.get_or_insert_text("text");
        let edits: Arc<Mutex<Vec<(u32, u32, String)>>> = Arc::default();
        let sink = edits.clone();
        // Swift already has its own edits; only remote changes and undos go back to it.
        text.observe("swift", move |txn, event| {
            if txn.origin().is_none() {
                return;
            }
            let mut edits = sink.lock().unwrap();
            let mut position = 0u32;
            for delta in event.delta(txn) {
                match delta {
                    Delta::Retain(len, _) => position += len,
                    Delta::Deleted(len) => edits.push((position, *len, String::new())),
                    Delta::Inserted(Out::Any(Any::String(s)), _) => {
                        edits.push((position, 0, s.to_string()));
                        position += s.encode_utf16().count() as u32;
                    }
                    Delta::Inserted(..) => {}
                }
            }
        });
        let mut undo = UndoManager::with_options(undo::Options { capture_timeout_millis: 500, ..Default::default() });
        undo.expand_scope(&doc, &text);
        Session {
            key,
            doc,
            text,
            undo,
            edits,
            base,
            name,
            pending: Vec::new(),
            adopting: false,
            peers: HashMap::new(),
            selection: None,
            notified: false,
        }
    }

    fn string(&self) -> String {
        self.text.get_string(&self.doc.transact())
    }

    fn state(&self) -> Vec<u8> {
        self.doc.transact().encode_state_as_update_v1(&StateVector::default())
    }

    fn state_vector(&self) -> StateVector {
        self.doc.transact().state_vector()
    }

    fn apply(&self, update: &[u8]) {
        if let Ok(update) = Update::decode_v1(update) {
            let _ = self.doc.transact_mut_with(REMOTE).apply_update(update);
        }
    }

    /// Applies Swift's text as one local edit; returns the update to send, if anything changed.
    fn set(&mut self, new: &str) -> Option<Vec<u8>> {
        let old = self.string();
        if old == new {
            return None;
        }
        let (start, removed, inserted) = diff(&old, new);
        let before = self.state_vector();
        {
            let mut txn = self.doc.transact_mut();
            if removed > 0 {
                self.text.remove_range(&mut txn, start, removed);
            }
            if !inserted.is_empty() {
                self.text.insert(&mut txn, start, &inserted);
            }
        }
        Some(self.doc.transact().encode_state_as_update_v1(&before))
    }

    fn sticky(&self, offset: u32) -> Vec<u8> {
        let txn = self.doc.transact();
        let len = self.text.len(&txn);
        self.text.sticky_index(&txn, offset.min(len), Assoc::After)
            .map(|index| index.encode_v1())
            .unwrap_or_default()
    }

    fn offset(&self, index: &Option<StickyIndex>) -> Option<u32> {
        let txn = self.doc.transact();
        index.as_ref()?.get_offset(&txn).map(|offset| offset.index)
    }
}

/// The changed span between two texts in UTF-16 offsets: start, removed length and the inserted text.
fn diff(old: &str, new: &str) -> (u32, u32, String) {
    let a: Vec<u16> = old.encode_utf16().collect();
    let b: Vec<u16> = new.encode_utf16().collect();
    let mut prefix = a.iter().zip(&b).take_while(|(x, y)| x == y).count();
    let max_suffix = a.len().min(b.len()) - prefix;
    let mut suffix = a.iter().rev().zip(b.iter().rev()).take(max_suffix).take_while(|(x, y)| x == y).count();
    // Never split a surrogate pair.
    while prefix > 0 && (0xDC00..0xE000).contains(&a.get(prefix).copied().unwrap_or(0)) {
        prefix -= 1;
    }
    while suffix > 0 && suffix < a.len() && (0xD800..0xDC00).contains(&a[a.len() - suffix - 1]) {
        suffix -= 1;
    }
    let inserted = String::from_utf16_lossy(&b[prefix..b.len() - suffix]);
    (prefix as u32, (a.len() - suffix - prefix) as u32, inserted)
}

fn now_key() -> SessionKey {
    let millis = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0);
    (millis, rand::random())
}

/// Shared spaces' topics derive from the space's secret, so every account lands on the same one.
fn topic_id(inner: &Inner, space: &str) -> TopicId {
    if inner.is_shared(space) {
        TopicId::from_bytes(derive("typewright 2026-10 shared live v0", &[&inner.namespace(space)]))
    } else {
        TopicId::from_bytes(derive("typewright 2026-10 live v0", &[&inner.account, space.as_bytes()]))
    }
}

impl Inner {
    fn send(&self, space: &str, path: &str, body: Body) {
        let envelope = Envelope { from: self.endpoint.id().to_string(), nonce: rand::random(), path: path.to_string(), body };
        let Ok(bytes) = postcard::to_allocvec(&envelope) else { return };
        if let Some(topic) = self.topics.lock().unwrap().get(space) {
            let _ = topic.outbox.send(Bytes::from(bytes));
        }
    }

    /// Tells Swift once that a file has news; it collects them with `sync`.
    fn notify(&self, space: &str, path: &str, session: &mut Session) {
        if !session.notified {
            session.notified = true;
            self.emit(json!({"type": "live", "space": space, "path": path}));
        }
    }
}

/// Joins the space's topic with the other devices syncing it.
pub(crate) async fn join(inner: &Arc<Inner>, space: &str) -> anyhow::Result<()> {
    if inner.topics.lock().unwrap().contains_key(space) {
        return Ok(());
    }
    let id = topic_id(inner, space);
    let (sender, mut receiver) = inner.gossip.subscribe(id, inner.space_peers(space)).await?.split();
    let (outbox, mut queue) = mpsc::unbounded_channel::<Bytes>();
    let out = sender.clone();
    let writer = tokio::spawn(async move {
        while let Some(message) = queue.recv().await {
            let _ = out.broadcast(message).await;
        }
    });
    let reader = {
        let inner = inner.clone();
        let space = space.to_string();
        tokio::spawn(async move {
            while let Some(event) = receiver.next().await {
                match event {
                    Ok(Event::Received(message)) => {
                        if let Ok(envelope) = postcard::from_bytes::<Envelope>(&message.content) {
                            receive(&inner, &space, envelope);
                        }
                    }
                    Ok(_) => {}
                    Err(_) => break,
                }
            }
        })
    };
    let heartbeat = {
        let inner = inner.clone();
        let space = space.to_string();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(HEARTBEAT).await;
                heartbeat(&inner, &space);
            }
        })
    };
    inner.topics.lock().unwrap().insert(space.to_string(), Topic { id, outbox, sender, tasks: vec![writer, reader, heartbeat] });
    Ok(())
}

/// Moves spaces that became shared to their shared topic; open sessions carry over and meet the others there.
pub(crate) async fn retopic(inner: &Arc<Inner>) {
    let moved: Vec<String> = {
        let mut topics = inner.topics.lock().unwrap();
        let moved: Vec<String> = topics.iter().filter(|(space, topic)| topic.id != topic_id(inner, space)).map(|(s, _)| s.clone()).collect();
        moved.iter().for_each(|space| drop(topics.remove(space)));
        moved
    };
    for space in moved {
        if let Err(err) = join(inner, &space).await {
            inner.error("live topic", err);
        }
    }
}

pub(crate) fn leave(inner: &Inner, space: &str) {
    inner.topics.lock().unwrap().remove(space);
    inner.live.lock().unwrap().retain(|(s, _), _| s != space);
}

/// Dials devices that showed up in a directory since the topic was joined.
pub(crate) async fn add_peers(inner: &Inner, space: &str, peers: Vec<EndpointId>) {
    let sender = inner.topics.lock().unwrap().get(space).map(|t| t.sender.clone());
    if let Some(sender) = sender {
        let _ = sender.join_peers(peers).await;
    }
}

fn receive(inner: &Inner, space: &str, envelope: Envelope) {
    if envelope.from == inner.endpoint.id().to_string() {
        return;
    }
    let mut live = inner.live.lock().unwrap();
    let Some(session) = live.get_mut(&(space.to_string(), envelope.path.clone())) else { return };
    let path = envelope.path.as_str();
    let from = envelope.from;
    let seen = |session: &mut Session| {
        session.peers.entry(from.clone()).or_insert_with(|| Peer { name: String::new(), anchor: None, head: None, seen: Instant::now() }).seen =
            Instant::now();
    };
    match envelope.body {
        Body::State { session: key, update, reply } => {
            seen(session);
            if key == session.key {
                session.pending.push(Pending::Update(update));
                if reply && !session.adopting {
                    inner.send(space, path, Body::State { session: session.key, update: session.state(), reply: false });
                }
            } else if key < session.key || session.adopting {
                session.key = key;
                session.adopting = true;
                session.pending = vec![Pending::Adopt(update)];
                for peer in session.peers.values_mut() {
                    peer.anchor = None;
                    peer.head = None;
                }
            } else {
                inner.send(space, path, Body::State { session: session.key, update: session.state(), reply: false });
            }
            inner.notify(space, path, session);
        }
        Body::Update { session: key, update } => {
            seen(session);
            if key == session.key {
                session.pending.push(Pending::Update(update));
                inner.notify(space, path, session);
            } else if !session.adopting {
                // An older session answers with its state, a newer one adopts ours.
                inner.send(space, path, Body::State { session: session.key, update: session.state(), reply: key < session.key });
            }
        }
        Body::Cursor { session: key, name, anchor, head } => {
            seen(session);
            if key == session.key {
                let peer = session.peers.get_mut(&from).unwrap();
                peer.name = name;
                peer.anchor = StickyIndex::decode_v1(&anchor).ok();
                peer.head = StickyIndex::decode_v1(&head).ok();
                inner.notify(space, path, session);
            }
        }
        Body::Sync { session: key, state } => {
            seen(session);
            // Sessions that met without anyone typing, as after moving topics: the older one hands over its state.
            if key > session.key && !session.adopting {
                inner.send(space, path, Body::State { session: session.key, update: session.state(), reply: false });
                return;
            }
            if key != session.key || session.adopting {
                return;
            }
            let Ok(theirs) = StateVector::decode_v1(&state) else { return };
            // Only answer with what they lack.
            let ours = session.state_vector();
            if ours.iter().any(|(client, clock)| theirs.get(client) < *clock) {
                let update = session.doc.transact().encode_state_as_update_v1(&theirs);
                inner.send(space, path, Body::Update { session: session.key, update });
            }
        }
        Body::Leave => {
            if session.peers.remove(&from).is_some() {
                inner.notify(space, path, session);
            }
        }
    }
}

fn heartbeat(inner: &Inner, space: &str) {
    let mut live = inner.live.lock().unwrap();
    for ((s, path), session) in live.iter_mut().filter(|((s, _), session)| s == space && !session.adopting) {
        let before = session.peers.len();
        session.peers.retain(|_, peer| peer.seen.elapsed() < PEER_TIMEOUT);
        if session.peers.len() != before {
            inner.notify(s, path, session);
        }
        let state = session.state_vector().encode_v1();
        inner.send(s, path, Body::Sync { session: session.key, state });
        send_cursor(inner, s, path, session);
    }
}

fn send_cursor(inner: &Inner, space: &str, path: &str, session: &Session) {
    let (location, length) = session.selection.unwrap_or((0, 0));
    let anchor = session.sticky(location);
    let head = session.sticky(location + length);
    inner.send(space, path, Body::Cursor { session: session.key, name: session.name.clone(), anchor, head });
}

/// Starts a session for a file opened in an editor; devices with it open already answer with theirs.
pub(crate) fn open(inner: &Inner, space: &str, path: &str, text: &str, name: &str) {
    let mut live = inner.live.lock().unwrap();
    let key = (space.to_string(), path.to_string());
    if live.contains_key(&key) {
        return;
    }
    let mut session = Session::new(now_key(), name.to_string(), text.to_string());
    session.set(text);
    inner.send(space, path, Body::State { session: session.key, update: session.state(), reply: true });
    live.insert(key, session);
}

pub(crate) fn close(inner: &Inner, space: &str, path: &str) {
    if inner.live.lock().unwrap().remove(&(space.to_string(), path.to_string())).is_some() {
        inner.send(space, path, Body::Leave);
    }
}

pub(crate) enum Step {
    None,
    Undo,
    Redo,
}

/// Swift's text and selection go in; remote edits, an adopted session and the other cursors come out as JSON.
pub(crate) fn sync(inner: &Inner, space: &str, path: &str, text: &str, selection: (u32, u32), step: Step) -> serde_json::Value {
    let mut live = inner.live.lock().unwrap();
    let Some(session) = live.get_mut(&(space.to_string(), path.to_string())) else { return json!({}) };
    session.notified = false;
    let mut adopted = serde_json::Value::Null;
    // Swift's text belongs to the old session; it merges it into the adopted one and syncs again.
    if !session.adopting {
        if let Some(update) = session.set(text) {
            inner.send(space, path, Body::Update { session: session.key, update });
        }
    }
    for pending in std::mem::take(&mut session.pending) {
        match pending {
            Pending::Update(update) => session.apply(&update),
            Pending::Adopt(update) => {
                let mut fresh = Session::new(session.key, session.name.clone(), String::new());
                fresh.apply(&update);
                fresh.edits.lock().unwrap().clear();
                fresh.base = fresh.string();
                fresh.peers = std::mem::take(&mut session.peers);
                adopted = json!({"base": session.base, "theirs": fresh.base});
                *session = fresh;
                session.selection = Some(selection);
            }
        }
    }
    let before = session.state_vector();
    let local = match step {
        _ if !adopted.is_null() => None,
        Step::None => None,
        Step::Undo => Some(session.undo.undo_blocking()),
        Step::Redo => Some(session.undo.redo_blocking()),
    };
    if local == Some(true) {
        // Undoing is a local change the others need too.
        let update = session.doc.transact().encode_state_as_update_v1(&before);
        inner.send(space, path, Body::Update { session: session.key, update });
    }
    // An adopted text replaces Swift's whole buffer, so earlier edits don't apply to it.
    let edits: Vec<_> = std::mem::take(&mut *session.edits.lock().unwrap());
    let edits: Vec<_> = if adopted.is_null() {
        edits.into_iter().map(|(location, length, text)| json!({"location": location, "length": length, "text": text})).collect()
    } else {
        Vec::new()
    };
    if session.selection != Some(selection) || local == Some(true) {
        session.selection = Some(selection);
        send_cursor(inner, space, path, session);
    }
    let cursors: Vec<_> = session
        .peers
        .iter()
        .filter_map(|(device, peer)| {
            let anchor = session.offset(&peer.anchor)?;
            let head = session.offset(&peer.head).unwrap_or(anchor);
            Some(json!({"device": device, "name": peer.name, "location": anchor.min(head), "length": anchor.abs_diff(head)}))
        })
        .collect();
    json!({
        "edits": edits,
        "adopted": adopted,
        "cursors": cursors,
        "peers": session.peers.len(),
        "undone": local.unwrap_or(false),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(text: &str) -> Session {
        let mut session = Session::new(now_key(), "Mac".into(), text.into());
        session.set(text);
        session
    }

    fn take_edits(session: &Session) -> Vec<(u32, u32, String)> {
        std::mem::take(&mut *session.edits.lock().unwrap())
    }

    #[test]
    fn diffs_in_utf16_without_splitting_pairs() {
        assert_eq!(diff("abc", "abXc"), (2, 0, "X".into()));
        assert_eq!(diff("a😀b", "a😃b"), (1, 2, "😃".into()));
        assert_eq!(diff("aaa", "aa"), (2, 1, "".into()));
        assert_eq!(diff("", "x"), (0, 0, "x".into()));
    }

    #[test]
    fn concurrent_edits_merge_and_come_back_as_edits() {
        let mut a = session("hello world");
        let mut b = Session::new(a.key, "Other".into(), String::new());
        b.apply(&a.state());
        take_edits(&b);
        let from_a = a.set("hello brave world").unwrap();
        let from_b = b.set("hello world!").unwrap();
        a.apply(&from_b);
        b.apply(&from_a);
        assert_eq!(a.string(), "hello brave world!");
        assert_eq!(b.string(), a.string());
        // Only the remote change reaches Swift, as an edit of the text Swift had.
        assert_eq!(take_edits(&a), vec![(17, 0, "!".into())]);
        assert_eq!(take_edits(&b), vec![(6, 0, "brave ".into())]);
    }

    #[test]
    fn undo_takes_back_only_own_edits() {
        let mut a = session("one");
        let mut b = Session::new(a.key, "Other".into(), String::new());
        b.apply(&a.state());
        a.undo.reset();
        let mine = a.set("one two").unwrap();
        b.apply(&mine);
        let theirs = b.set("zero one two").unwrap();
        a.apply(&theirs);
        take_edits(&a);
        assert!(a.undo.undo_blocking());
        assert_eq!(a.string(), "zero one");
        assert_eq!(take_edits(&a), vec![(8, 4, String::new())]);
    }

    #[test]
    fn cursors_follow_remote_edits() {
        let mut a = session("abc");
        let mut b = Session::new(a.key, "Other".into(), String::new());
        b.apply(&a.state());
        let cursor = StickyIndex::decode_v1(&b.sticky(2)).ok();
        b.apply(&a.set("XYabc").unwrap());
        assert_eq!(b.offset(&cursor), Some(4));
    }
}
