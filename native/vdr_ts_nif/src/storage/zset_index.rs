use std::borrow::Borrow;
use std::cmp::Ordering;
use ouroboros::self_referencing;
use ordered_float::OrderedFloat;
use super::bytes::Bytes;

pub type Score = OrderedFloat<f64>;

pub enum ZSetIndexKeyRef<'a> {
    MinScoreKey(Score),
    MaxScoreKey(Score),
    Key { score: Score, entry: &'a [u8] },
}

enum ZSetIndexKeyData {
    MinScoreKey(Score),
    MaxScoreKey(Score),
    Key{ score: Score, entry: Bytes },
}

#[self_referencing]
pub struct ZSetIndexKey {
    data: ZSetIndexKeyData,
    #[borrows(data)]
    #[covariant]
    ref_view: ZSetIndexKeyRef<'this>,
}

impl ZSetIndexKey {
    pub fn create(score: Score, data: &[u8]) -> Self {
        ZSetIndexKeyBuilder {
            data: ZSetIndexKeyData::Key { score: score, entry: Bytes::new(data)},
            ref_view_builder: |data: &ZSetIndexKeyData| match data {
                ZSetIndexKeyData::Key { score, entry } => ZSetIndexKeyRef::Key { score: *score, entry: entry.borrow() },
                _ => unreachable!(),
            },
        }
        .build()
    }

    pub fn min_score_key(score: Score) -> Self {
        ZSetIndexKeyBuilder {
            data: ZSetIndexKeyData::MinScoreKey(score),
            ref_view_builder: |data: &ZSetIndexKeyData| match data {
                ZSetIndexKeyData::MinScoreKey(score) => ZSetIndexKeyRef::MinScoreKey(*score),
                _ => unreachable!(),
            },
        }
        .build()
    }

    pub fn max_score_key(score: Score) -> Self {
        ZSetIndexKeyBuilder {
            data: ZSetIndexKeyData::MaxScoreKey(score),
            ref_view_builder: |data: &ZSetIndexKeyData| match data {
                ZSetIndexKeyData::MaxScoreKey(score) => ZSetIndexKeyRef::MaxScoreKey(*score),
                _ => unreachable!(),
            },
        }
        .build()
    }

    pub fn get_entry_and_score(&self) -> Option<(Bytes, Score)> {
        self.with_data(|data| {
            if let ZSetIndexKeyData::Key { score, entry } = data {
                Some((entry.clone(), *score))
            } else {
                None
            }
        })
    }
}

impl Borrow<ZSetIndexKeyRef<'static>> for ZSetIndexKey {
    fn borrow(&self) -> &ZSetIndexKeyRef<'static> {
        unsafe { std::mem::transmute(self.borrow_ref_view()) }
    }
}

impl<'a> ZSetIndexKeyRef<'a> {
    pub fn lookup_key_ref(score: Score, member: &'a [u8]) -> ZSetIndexKeyRef<'static> {
        unsafe { ZSetIndexKeyRef::Key { score, entry: std::mem::transmute(member) } }
    }
}

impl ZSetIndexKey {
    fn as_ref<'a>(&'a self) -> &'a ZSetIndexKeyRef<'a> {
        self.borrow_ref_view()
    }
}

// Implement ordering traits by delegating to the contained ZSetIndexKeyRef
impl PartialEq for ZSetIndexKey {
    fn eq(&self, other: &Self) -> bool {
        self.as_ref() == other.as_ref()
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
        self.as_ref().cmp(other.as_ref())
    }
}


impl<'a> PartialEq for ZSetIndexKeyRef<'a> {
    fn eq(&self, other: &Self) -> bool {
        matches!(self.cmp(other), Ordering::Equal)
    }
}

impl<'a> Eq for ZSetIndexKeyRef<'a> {}

impl<'a> PartialOrd for ZSetIndexKeyRef<'a> {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl<'a> Ord for ZSetIndexKeyRef<'a> {
    fn cmp(&self, other: &Self) -> Ordering {
        use ZSetIndexKeyRef::*;

        match (self, other) {
            // MinScoreKey comparisons
            (MinScoreKey(_), MinScoreKey(_)) => unreachable!(),
            (MinScoreKey(_), MaxScoreKey(_)) => unreachable!(),
            (MaxScoreKey(_), MaxScoreKey(_)) => unreachable!(),
            (MaxScoreKey(_), MinScoreKey(_)) => unreachable!(),

            (MinScoreKey(s1), Key { score: s2, .. }) => {
                match s1.cmp(s2) {
                    Ordering::Equal => Ordering::Less,  // MinScore < Key for same score
                    other => other,
                }
            }
            (MaxScoreKey(s1), Key { score: s2, .. }) => {
                match s1.cmp(s2) {
                    Ordering::Equal => Ordering::Greater,  // MaxScore > Key for same score
                    other => other,
                }
            }

            // Key comparisons
            (Key { score: s1, .. }, MinScoreKey(s2)) => {
                match s1.cmp(s2) {
                    Ordering::Equal => Ordering::Greater,  // Key > MinScore for same score
                    other => other,
                }
            }
            (Key { score: s1, .. }, MaxScoreKey(s2)) => {
                match s1.cmp(s2) {
                    Ordering::Equal => Ordering::Less,  // Key < MaxScore for same score
                    other => other,
                }
            }
            (Key { score: s1, entry: e1 }, Key { score: s2, entry: e2 }) => {
                // First compare scores, then entries lexicographically
                match s1.cmp(s2) {
                    Ordering::Equal => e1.cmp(e2),
                    other => other,
                }
            }
        }
    }
}
