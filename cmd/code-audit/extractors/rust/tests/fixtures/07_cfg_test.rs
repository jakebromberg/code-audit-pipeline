/// Production type — `is_test` must be false.
pub struct RealType {
    pub x: u32,
}

#[cfg(test)]
mod tests {
    /// Declared inside a `#[cfg(test)]` module — `is_test` must be true.
    pub struct TestOnly {
        pub y: u32,
    }
}
