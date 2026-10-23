//! Which autosaves to keep, the way backup tools prune (borg's `--keep-*` rules): the newest `last` commits, then the
//! newest commit of each of the most recent hours, days, ISO weeks, months and years that have commits.
use anyhow::{Result, anyhow};
use serde_json::Value;

/// How many of each to keep; negative means unlimited, 0 turns a rule off.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Policy {
    pub last: i64,
    pub hourly: i64,
    pub daily: i64,
    pub weekly: i64,
    pub monthly: i64,
    pub yearly: i64,
}

impl Default for Policy {
    fn default() -> Self { Policy { last: 100, hourly: 48, daily: 14, weekly: 8, monthly: 12, yearly: -1 } }
}

impl Policy {
    /// `{"last": 100, …}`: missing keys take the defaults, `null` or a negative number means unlimited.
    pub fn parse(json: &str) -> Result<Policy> {
        let value: Value = serde_json::from_str(json)?;
        let object = value.as_object().ok_or_else(|| anyhow!("the policy must be an object"))?;
        let mut policy = Policy::default();
        for (key, value) in object {
            let slot = match key.as_str() {
                "last" => &mut policy.last,
                "hourly" => &mut policy.hourly,
                "daily" => &mut policy.daily,
                "weekly" => &mut policy.weekly,
                "monthly" => &mut policy.monthly,
                "yearly" => &mut policy.yearly,
                _ => return Err(anyhow!("unknown policy key {key:?}")),
            };
            *slot = match value {
                Value::Null => -1,
                v => v.as_i64().ok_or_else(|| anyhow!("{key} must be a whole number or null"))?,
            };
        }
        Ok(policy)
    }
}

/// A commit as retention sees it. `offset` is its time zone (minutes east of UTC) when it was made, so periods follow
/// the local clock across DST changes; `pinned` commits are always kept and count as kept for every rule.
#[derive(Clone, Copy, Debug)]
pub struct Item {
    pub millis: i64,
    pub offset: i32,
    pub pinned: bool,
}

/// Keep flags for `items`, newest first. Each rule only counts periods whose newest commit isn't already kept by an
/// earlier rule (as borg does), so the rules reach back one after another.
pub fn keep(items: &[Item], policy: &Policy) -> Vec<bool> {
    let mut kept: Vec<bool> = items.iter().map(|i| i.pinned).collect();
    let locals: Vec<i64> = items.iter().map(|i| i.millis.div_euclid(1000) + i64::from(i.offset) * 60).collect();
    let mut rule = |n: i64, period: &dyn Fn(usize, i64) -> i64| {
        if n == 0 {
            return;
        }
        let mut count = 0;
        let mut last = None;
        for (i, &local) in locals.iter().enumerate() {
            let key = period(i, local);
            if last == Some(key) {
                continue;
            }
            last = Some(key);
            if !kept[i] {
                kept[i] = true;
                count += 1;
                if count == n {
                    break;
                }
            }
        }
    };
    rule(policy.last, &|i, _| i as i64);
    rule(policy.hourly, &|_, s| s.div_euclid(3600));
    rule(policy.daily, &|_, s| s.div_euclid(86_400));
    // 1970-01-01 was a Thursday; shifting by 3 days makes weeks start on Monday (ISO).
    rule(policy.weekly, &|_, s| (s.div_euclid(86_400) + 3).div_euclid(7));
    rule(policy.monthly, &|_, s| {
        let (y, m) = year_month(s.div_euclid(86_400));
        y * 12 + m
    });
    rule(policy.yearly, &|_, s| year_month(s.div_euclid(86_400)).0);
    kept
}

/// Civil year and month (0-based) of a day count since 1970-01-01 (Howard Hinnant's `civil_from_days`).
fn year_month(days: i64) -> (i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let month = if mp < 10 { mp + 2 } else { mp - 10 };
    let year = yoe + era * 400 + i64::from(month < 2);
    (year, month)
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOUR: i64 = 3_600_000;
    const DAY: i64 = 24 * HOUR;
    /// 2025-01-06 00:00 UTC, a Monday.
    const MONDAY: i64 = 20_094 * DAY;

    fn off() -> Policy { Policy { last: 0, hourly: 0, daily: 0, weekly: 0, monthly: 0, yearly: 0 } }

    /// Items newest first from times given oldest first.
    fn items(times: &[i64]) -> Vec<Item> {
        times.iter().rev().map(|&millis| Item { millis, offset: 0, pinned: false }).collect()
    }

    /// Kept times, oldest first.
    fn kept_times(items: &[Item], policy: &Policy) -> Vec<i64> {
        let flags = keep(items, policy);
        let mut out: Vec<i64> = items.iter().zip(flags).filter(|(_, k)| *k).map(|(i, _)| i.millis).collect();
        out.reverse();
        out
    }

    /// Runs the policy, drops what it didn't keep and runs it again on the rest.
    fn twice(items: &[Item], policy: &Policy) -> (Vec<Item>, Vec<bool>) {
        let flags = keep(items, policy);
        let rest: Vec<Item> = items.iter().zip(&flags).filter(|(_, k)| **k).map(|(i, _)| *i).collect();
        let again = keep(&rest, policy);
        (rest, again)
    }

    #[test]
    fn parses_with_defaults() {
        assert_eq!(Policy::parse("{}").unwrap(), Policy::default());
        let p = Policy::parse(r#"{"last": 5, "yearly": null, "daily": 0}"#).unwrap();
        assert_eq!((p.last, p.yearly, p.daily, p.hourly), (5, -1, 0, 48));
        assert!(Policy::parse(r#"{"lats": 1}"#).is_err());
        assert!(Policy::parse(r#"{"last": "x"}"#).is_err());
    }

    #[test]
    fn last_keeps_the_newest() {
        let it = items(&[1, 2, 3, 4, 5].map(|i| MONDAY + i * 1000));
        assert_eq!(kept_times(&it, &Policy { last: 2, ..off() }), [MONDAY + 4000, MONDAY + 5000]);
        assert!(kept_times(&it, &off()).is_empty());
        assert_eq!(kept_times(&it, &Policy { last: -1, ..off() }).len(), 5);
    }

    #[test]
    fn hourly_keeps_the_newest_per_hour() {
        let t = [MONDAY + 60_000, MONDAY + 120_000, MONDAY + HOUR + 1, MONDAY + HOUR + 5, MONDAY + 3 * HOUR];
        let it = items(&t);
        assert_eq!(kept_times(&it, &Policy { hourly: -1, ..off() }), [t[1], t[3], t[4]]);
        assert_eq!(kept_times(&it, &Policy { hourly: 2, ..off() }), [t[3], t[4]]);
    }

    #[test]
    fn empty_periods_dont_count() {
        // Three days with commits, a month apart: daily 3 keeps all three.
        let t = [MONDAY, MONDAY + 30 * DAY, MONDAY + 60 * DAY];
        assert_eq!(kept_times(&items(&t), &Policy { daily: 3, ..off() }), t);
    }

    #[test]
    fn rules_reach_back_one_after_another() {
        // Ten commits on each of five days. last 3 takes today's newest three; daily 2 then takes the newest of the
        // two days before (today's newest is already kept, so today doesn't count).
        let mut t = Vec::new();
        for d in 0..5 {
            for m in 0..10 {
                t.push(MONDAY + d * DAY + m * 60_000);
            }
        }
        let kept = kept_times(&items(&t), &Policy { last: 3, daily: 2, ..off() });
        assert_eq!(kept, [MONDAY + 2 * DAY + 540_000, MONDAY + 3 * DAY + 540_000, t[47], t[48], t[49]]);
    }

    #[test]
    fn weekly_monthly_yearly_boundaries() {
        let sunday = MONDAY - DAY + 23 * HOUR;
        let it = items(&[sunday - DAY, sunday, MONDAY, MONDAY + DAY]);
        assert_eq!(kept_times(&it, &Policy { weekly: -1, ..off() }), [sunday, MONDAY + DAY]);
        // 2024-12-31 23:00 and 2025-01-01 00:30 are different months and years.
        let new_year = MONDAY - 5 * DAY;
        let it = items(&[new_year - 2 * DAY, new_year - HOUR, new_year + HOUR / 2]);
        assert_eq!(kept_times(&it, &Policy { monthly: -1, ..off() }), [new_year - HOUR, new_year + HOUR / 2]);
        assert_eq!(kept_times(&it, &Policy { yearly: -1, ..off() }), [new_year - HOUR, new_year + HOUR / 2]);
        assert_eq!(year_month(0), (1970, 0));
        assert_eq!(year_month(20_089), (2025, 0));
        assert_eq!(year_month(19_782), (2024, 1), "2024-02-29");
        assert_eq!(year_month(-1), (1969, 11));
    }

    #[test]
    fn periods_follow_the_local_clock() {
        // 22:30 UTC is the same day in UTC but the next day at UTC+2.
        let a = Item { millis: MONDAY + 22 * HOUR + HOUR / 2, offset: 0, pinned: false };
        let b = Item { millis: MONDAY + 23 * HOUR, offset: 0, pinned: false };
        assert_eq!(keep(&[b, a], &Policy { daily: -1, ..off() }), [true, false]);
        let b = Item { offset: 120, ..b };
        assert_eq!(keep(&[b, a], &Policy { daily: -1, ..off() }), [true, true]);
        // A DST change between two commits (01:30 at +1, then 03:10 at +2 an hour later) splits hours by local time.
        let before = Item { millis: MONDAY + HOUR / 2, offset: 60, pinned: false };
        let after = Item { millis: MONDAY + HOUR + HOUR / 6, offset: 120, pinned: false };
        assert_eq!(keep(&[after, before], &Policy { hourly: -1, ..off() }), [true, true]);
        assert_eq!(keep(&[after, before], &Policy { daily: -1, ..off() }), [true, false]);
    }

    #[test]
    fn pinned_commits_are_kept_and_count_as_kept() {
        let mut it = items(&[MONDAY, MONDAY + 1000, MONDAY + DAY, MONDAY + DAY + 1000]);
        it[0].pinned = true;
        it[3].pinned = true;
        // Day 2's newest is pinned, so daily 1 doesn't count day 2 and takes day 1's newest instead.
        assert_eq!(keep(&it, &Policy { daily: 1, ..off() }), [true, false, true, true]);
        assert_eq!(keep(&it, &off()), [true, false, false, true]);
    }

    #[test]
    fn idempotent() {
        let mut t = Vec::new();
        let mut x: i64 = 7;
        let mut time = MONDAY;
        for _ in 0..3000 {
            x = x.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
            time += (x.rem_euclid(5 * HOUR)) + 5000;
            t.push(time);
        }
        let mut it = items(&t);
        for (i, item) in it.iter_mut().enumerate() {
            item.pinned = i % 97 == 0;
            item.offset = if i % 2 == 0 { 60 } else { 120 };
        }
        for policy in [Policy::default(), Policy { last: 3, hourly: 5, daily: 7, weekly: 2, monthly: 3, yearly: 1 }] {
            let (_, again) = twice(&it, &policy);
            assert!(again.iter().all(|k| *k), "{policy:?}");
        }
    }

    #[test]
    fn long_history_is_fast() {
        // 20k commits over three years.
        let span = 3 * 365 * DAY;
        let t: Vec<i64> = (0..20_000).map(|i| MONDAY + i * (span / 20_000)).collect();
        let it = items(&t);
        let start = std::time::Instant::now();
        let flags = keep(&it, &Policy::default());
        assert!(start.elapsed() < std::time::Duration::from_millis(200), "{:?}", start.elapsed());
        let kept = flags.iter().filter(|k| **k).count();
        // 100 last + 48 hours + 14 days + 8 weeks + 12 months + up to 4 years.
        assert!(kept <= 100 + 48 + 14 + 8 + 12 + 4, "{kept}");
        assert!(kept >= 100 + 48 + 14 + 8 + 12, "{kept}");
    }
}
