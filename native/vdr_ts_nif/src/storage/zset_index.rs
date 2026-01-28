use super::bytes::Bytes;
use ordered_float::OrderedFloat;
use std::cmp::Ordering;

pub type Score = OrderedFloat<f64>;

pub enum ZSetIndexKey {
    Key { score: Score, entry: Bytes },
    // We do not actually store these Keys, but we use them for searching
    MinScoreKey(Score),
    MaxScoreKey(Score),
    Ref { score: Score, entry: &'static [u8] },
}

impl ZSetIndexKey {
    pub fn create(score: Score, data: &[u8]) -> Self {
        ZSetIndexKey::Key {
            score: score,
            entry: Bytes::new(data),
        }
    }

    pub fn min_score_key(score: Score) -> Self {
        ZSetIndexKey::MinScoreKey(score)
    }

    pub fn max_score_key(score: Score) -> Self {
        ZSetIndexKey::MaxScoreKey(score)
    }

    pub fn create_ref(score: Score, entry: &[u8]) -> Self {
        ZSetIndexKey::Ref {
            score: score,
            entry: unsafe { std::mem::transmute(entry) },
        }
    }

    pub fn unwrap_key(&self) -> (&Score, &Bytes) {
        match self {
            ZSetIndexKey::Key { score, entry } => (score, entry),
            _ => unreachable!(),
        }
    }
}

// Implement ordering traits by delegating to the contained ZSetIndexKeyRef
impl PartialEq for ZSetIndexKey {
    fn eq(&self, other: &Self) -> bool {
        use ZSetIndexKey::*;
        match (self, other) {
            (
                Key {
                    score: s1,
                    entry: e1,
                },
                Key {
                    score: s2,
                    entry: e2,
                },
            ) => s1 == s2 && e1 == e2,
            (
                Key {
                    score: s1,
                    entry: e1,
                },
                Ref {
                    score: s2,
                    entry: e2,
                },
            ) => s1 == s2 && &e1.as_slice() == e2,
            (
                Ref {
                    score: s1,
                    entry: e1,
                },
                Key {
                    score: s2,
                    entry: e2,
                },
            ) => s1 == s2 && e1 == &e2.as_slice(),
            (Ref { score: _, entry: _ }, Ref { score: _, entry: _ }) => unreachable!(),
            (MinScoreKey(_), MinScoreKey(_)) => unreachable!(),
            (MinScoreKey(_), MaxScoreKey(_)) => unreachable!(),
            (MinScoreKey(_), Ref { score: _, entry: _ }) => unreachable!(),
            (MaxScoreKey(_), MaxScoreKey(_)) => unreachable!(),
            (MaxScoreKey(_), MinScoreKey(_)) => unreachable!(),
            (MaxScoreKey(_), Ref { score: _, entry: _ }) => unreachable!(),
            (Ref { score: _, entry: _ }, MinScoreKey(_)) => unreachable!(),
            (Ref { score: _, entry: _ }, MaxScoreKey(_)) => unreachable!(),
            (Key { score: _, entry: _ }, MinScoreKey(_)) => false,
            (Key { score: _, entry: _ }, MaxScoreKey(_)) => false,
            (MaxScoreKey(_), Key { score: _, entry: _ }) => false,
            (MinScoreKey(_), Key { score: _, entry: _ }) => false,
        }
    }
}

impl Eq for ZSetIndexKey {}

impl PartialOrd for ZSetIndexKey {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for ZSetIndexKey {
    fn cmp(&self, other: &Self) -> Ordering {
        use ZSetIndexKey::*;
        match (self, other) {
            // Lookup keys cannot be compared
            (MinScoreKey(_), MinScoreKey(_)) => unreachable!(),
            (MinScoreKey(_), MaxScoreKey(_)) => unreachable!(),
            (MinScoreKey(_), Ref { score: _, entry: _ }) => unreachable!(),
            (MaxScoreKey(_), MaxScoreKey(_)) => unreachable!(),
            (MaxScoreKey(_), MinScoreKey(_)) => unreachable!(),
            (MaxScoreKey(_), Ref { score: _, entry: _ }) => unreachable!(),
            (Ref { score: _, entry: _ }, MinScoreKey(_)) => unreachable!(),
            (Ref { score: _, entry: _ }, MaxScoreKey(_)) => unreachable!(),
            (Ref { score: _, entry: _ }, Ref { score: _, entry: _ }) => unreachable!(),

            // MinScoreKey comparisons
            (MinScoreKey(s1), Key { score: s2, .. }) => {
                match s1.cmp(s2) {
                    Ordering::Equal => Ordering::Less, // MinScore < Key for same score
                    other => other,
                }
            }
            (Key { score: s1, .. }, MinScoreKey(s2)) => {
                match s1.cmp(s2) {
                    Ordering::Equal => Ordering::Greater, // Key > MinScore for same score
                    other => other,
                }
            }

            // MaxScoreKey comparisons
            (MaxScoreKey(s1), Key { score: s2, .. }) => {
                match s1.cmp(s2) {
                    Ordering::Equal => Ordering::Greater, // MaxScore > Key for same score
                    other => other,
                }
            }
            (Key { score: s1, .. }, MaxScoreKey(s2)) => {
                match s1.cmp(s2) {
                    Ordering::Equal => Ordering::Less, // Key < MaxScore for same score
                    other => other,
                }
            }

            // Ref comparisons
            (
                Ref {
                    score: s1,
                    entry: e1,
                },
                Key {
                    score: s2,
                    entry: e2,
                },
            ) => match s1.cmp(s2) {
                Ordering::Equal => e1.cmp(&e2.as_slice()),
                other => other,
            },
            (
                Key {
                    score: s1,
                    entry: e1,
                },
                Ref {
                    score: s2,
                    entry: e2,
                },
            ) => match s1.cmp(s2) {
                Ordering::Equal => e1.as_slice().cmp(e2),
                other => other,
            },

            // Key comparisons
            (
                Key {
                    score: s1,
                    entry: e1,
                },
                Key {
                    score: s2,
                    entry: e2,
                },
            ) => {
                // First compare scores, then entries lexicographically
                match s1.cmp(s2) {
                    Ordering::Equal => e1.cmp(e2),
                    other => other,
                }
            }
        }
    }
}
