use std::borrow::Borrow;
use std::cmp::Ordering;
use std::rc::Rc;

#[derive(Clone, Debug)]
pub struct Bytes(Rc<Vec<u8>>);

// SAFETY: Bytes is only accessed while holding the storage mutex lock,
// so concurrent access is prevented at a higher level.
unsafe impl Send for Bytes {}
unsafe impl Sync for Bytes {}

impl Bytes {
    pub fn new(data: &[u8]) -> Self {
        Bytes(Rc::new(data.to_vec()))
    }

    pub fn as_slice(&self) -> &[u8] {
        &self.0
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    #[allow(dead_code)]
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

impl Borrow<[u8]> for Bytes {
    fn borrow(&self) -> &[u8] {
        &self.0
    }
}

impl PartialEq for Bytes {
    fn eq(&self, other: &Self) -> bool {
        self.0.as_slice() == other.0.as_slice()
    }
}

impl Eq for Bytes {}

impl PartialOrd for Bytes {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Bytes {
    fn cmp(&self, other: &Self) -> Ordering {
        self.0.as_slice().cmp(other.0.as_slice())
    }
}

impl std::hash::Hash for Bytes {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.0.as_slice().hash(state);
    }
}
