pub var counter: u32 = 0;

pub fn tick() void {
    counter += 1;
}

pub fn snapshot() u32 {
    return counter;
}
