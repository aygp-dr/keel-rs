//! The forth-keel kernel.
//!
//! One linear, byte-addressed memory laid out as the governing spec's memory
//! map (R-K-04), two stacks that grow down, the thirteen primitives of R-K-01,
//! and the NEXT inner interpreter. Nothing here parses text: the outer
//! interpreter is a `frames` word, written in Forth on top of this.
//!
//! Spec: <https://github.com/aygp-dr/forth-keel> (`spec.org`).
#![forbid(unsafe_code)]

use core::fmt;

/// A cell. R-K-03: cells are at least 32 bits and the sea-trials assume no
/// more than 32, so the kernel is exactly 32-bit on every host.
pub type Cell = i32;
/// A cell read as unsigned, and the type of every address.
pub type UCell = u32;
/// Bytes per cell.
pub const CELL: UCell = 4;

/// System variables, in the order the memory map names them.
pub const SYS_HERE: UCell = 0;
pub const SYS_LATEST: UCell = 1;
pub const SYS_STATE: UCell = 2;
pub const SYS_BASE: UCell = 3;
pub const SYS_HP: UCell = 4;
/// Cells reserved for system variables (the five above, plus spare).
pub const SYS_CELLS: UCell = 8;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    DataStackUnderflow,
    DataStackOverflow,
    ReturnStackUnderflow,
    ReturnStackOverflow,
    Unaligned(UCell),
    OutOfRange(UCell),
    DivideByZero,
    QuotientOverflow,
    DictionaryFull,
    StepLimit,
    BadSnapshot,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::DataStackUnderflow => write!(f, "data stack underflow"),
            Error::DataStackOverflow => write!(f, "data stack overflow"),
            Error::ReturnStackUnderflow => write!(f, "return stack underflow"),
            Error::ReturnStackOverflow => write!(f, "return stack overflow"),
            Error::Unaligned(a) => write!(f, "unaligned address {a}"),
            Error::OutOfRange(a) => write!(f, "address {a} outside memory"),
            Error::DivideByZero => write!(f, "divide by zero"),
            Error::QuotientOverflow => write!(f, "quotient does not fit in a cell"),
            Error::DictionaryFull => write!(f, "dictionary full"),
            Error::StepLimit => write!(f, "step limit reached"),
            Error::BadSnapshot => write!(f, "snapshot does not match this kernel"),
        }
    }
}

impl std::error::Error for Error {}

/// Region boundaries of the one linear memory (R-K-04). Regions appear in the
/// order the memory map gives them, and every boundary is cell-aligned. Both
/// stacks grow down from the top of their own region.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Layout {
    pub sys: UCell,
    pub tib: UCell,
    pub tib_size: UCell,
    pub dict: UCell,
    pub dict_size: UCell,
    pub from_space: UCell,
    pub to_space: UCell,
    pub semispace_size: UCell,
    pub data_stack: UCell,
    pub data_stack_size: UCell,
    pub return_stack: UCell,
    pub return_stack_size: UCell,
    pub end: UCell,
}

const fn align(n: UCell) -> UCell {
    n.div_ceil(CELL) * CELL
}

impl Layout {
    pub fn new(
        tib_size: UCell,
        dict_size: UCell,
        semispace_size: UCell,
        data_stack_size: UCell,
        return_stack_size: UCell,
    ) -> Self {
        let (tib_size, dict_size, semispace_size, data_stack_size, return_stack_size) = (
            align(tib_size),
            align(dict_size),
            align(semispace_size),
            align(data_stack_size),
            align(return_stack_size),
        );
        let sys = 0;
        let tib = sys + SYS_CELLS * CELL;
        let dict = tib + tib_size;
        let from_space = dict + dict_size;
        let to_space = from_space + semispace_size;
        let data_stack = to_space + semispace_size;
        let return_stack = data_stack + data_stack_size;
        let end = return_stack + return_stack_size;
        Self {
            sys,
            tib,
            tib_size,
            dict,
            dict_size,
            from_space,
            to_space,
            semispace_size,
            data_stack,
            data_stack_size,
            return_stack,
            return_stack_size,
            end,
        }
    }

    /// One cell past the top of the data stack: the pointer's empty value.
    pub fn data_stack_top(&self) -> UCell {
        self.data_stack + self.data_stack_size
    }

    /// One cell past the top of the return stack.
    pub fn return_stack_top(&self) -> UCell {
        self.return_stack + self.return_stack_size
    }

    /// Every region boundary, low to high, in memory-map order.
    pub fn boundaries(&self) -> [UCell; 8] {
        [
            self.sys,
            self.tib,
            self.dict,
            self.from_space,
            self.to_space,
            self.data_stack,
            self.return_stack,
            self.end,
        ]
    }
}

impl Default for Layout {
    fn default() -> Self {
        Self::new(256, 64 * 1024, 32 * 1024, 4 * 1024, 4 * 1024)
    }
}

/// The thirteen primitives of R-K-01, in the order the requirement lists them.
/// The discriminant is the execution token, so an xt below [`Prim::COUNT`] is a
/// primitive and any other xt is the body address of a colon definition.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum Prim {
    Fetch = 0,
    Store = 1,
    SpFetch = 2,
    RpFetch = 3,
    ZeroEquals = 4,
    Plus = 5,
    Nand = 6,
    Exit = 7,
    Key = 8,
    Emit = 9,
    Execute = 10,
    UmStar = 11,
    UmSlashMod = 12,
}

/// Primitive names, in R-K-01 order, indexed by execution token.
pub const PRIM_NAMES: [&str; 13] = [
    "@", "!", "sp@", "rp@", "0=", "+", "nand", "exit", "key", "emit", "execute", "um*", "um/mod",
];

impl Prim {
    /// How many primitives there are; also the first xt that is not one.
    pub const COUNT: Cell = 13;

    pub fn from_xt(xt: Cell) -> Option<Prim> {
        use Prim::*;
        Some(match xt {
            0 => Fetch,
            1 => Store,
            2 => SpFetch,
            3 => RpFetch,
            4 => ZeroEquals,
            5 => Plus,
            6 => Nand,
            7 => Exit,
            8 => Key,
            9 => Emit,
            10 => Execute,
            11 => UmStar,
            12 => UmSlashMod,
            _ => return None,
        })
    }

    pub fn xt(self) -> Cell {
        self as Cell
    }

    pub fn name(self) -> &'static str {
        PRIM_NAMES[self as usize]
    }

    pub fn by_name(name: &str) -> Option<Prim> {
        PRIM_NAMES
            .iter()
            .position(|n| *n == name)
            .and_then(|i| Prim::from_xt(i as Cell))
    }

    /// All thirteen, in R-K-01 order.
    pub fn all() -> [Prim; 13] {
        use Prim::*;
        [
            Fetch, Store, SpFetch, RpFetch, ZeroEquals, Plus, Nand, Exit, Key, Emit, Execute,
            UmStar, UmSlashMod,
        ]
    }
}

/// The true flag. Forth's canonical true is all bits set.
pub const TRUE: Cell = -1;
/// The false flag.
pub const FALSE: Cell = 0;

/// The kernel: memory, the two stacks, and the inner interpreter.
pub struct Vm {
    pub mem: Vec<u8>,
    pub layout: Layout,
    sp: UCell,
    rp: UCell,
    ip: UCell,
    rp_floor: UCell,
    running: bool,
    input: Vec<u8>,
    in_pos: usize,
    output: Vec<u8>,
}

impl Default for Vm {
    fn default() -> Self {
        Self::new(Layout::default())
    }
}

impl Vm {
    pub fn new(layout: Layout) -> Self {
        let mut vm = Vm {
            mem: vec![0; layout.end as usize],
            layout,
            sp: layout.data_stack_top(),
            rp: layout.return_stack_top(),
            ip: 0,
            rp_floor: layout.return_stack_top(),
            running: false,
            input: Vec::new(),
            in_pos: 0,
            output: Vec::new(),
        };
        vm.reset();
        vm
    }

    /// Clear both stacks and the buffers, and set the system variables to their
    /// initial values. Does not zero the dictionary.
    pub fn reset(&mut self) {
        self.sp = self.layout.data_stack_top();
        self.rp = self.layout.return_stack_top();
        self.rp_floor = self.rp;
        self.ip = 0;
        self.running = false;
        self.input.clear();
        self.in_pos = 0;
        self.output.clear();
        let dict = self.layout.dict;
        let from = self.layout.from_space;
        let _ = self.set_sys(SYS_HERE, dict as Cell);
        let _ = self.set_sys(SYS_LATEST, 0);
        let _ = self.set_sys(SYS_STATE, 0);
        let _ = self.set_sys(SYS_BASE, 10);
        let _ = self.set_sys(SYS_HP, from as Cell);
    }

    // ---- memory ----------------------------------------------------------

    // `is_multiple_of` would read better than `% CELL` but needs Rust 1.87,
    // above this crate's declared rust-version.
    #[allow(clippy::manual_is_multiple_of)]
    fn check(&self, addr: UCell) -> Result<(), Error> {
        if addr % CELL != 0 {
            return Err(Error::Unaligned(addr));
        }
        match addr.checked_add(CELL) {
            Some(end) if end <= self.layout.end => Ok(()),
            _ => Err(Error::OutOfRange(addr)),
        }
    }

    pub fn fetch(&self, addr: UCell) -> Result<Cell, Error> {
        self.check(addr)?;
        let i = addr as usize;
        let mut b = [0u8; 4];
        b.copy_from_slice(&self.mem[i..i + 4]);
        Ok(Cell::from_le_bytes(b))
    }

    pub fn store(&mut self, addr: UCell, v: Cell) -> Result<(), Error> {
        self.check(addr)?;
        let i = addr as usize;
        self.mem[i..i + 4].copy_from_slice(&v.to_le_bytes());
        Ok(())
    }

    pub fn sys(&self, index: UCell) -> Result<Cell, Error> {
        self.fetch(self.layout.sys + index * CELL)
    }

    pub fn set_sys(&mut self, index: UCell, v: Cell) -> Result<(), Error> {
        self.store(self.layout.sys + index * CELL, v)
    }

    pub fn here(&self) -> UCell {
        self.sys(SYS_HERE).unwrap_or(0) as UCell
    }

    /// Append one cell at HERE and advance it, as Forth's `,` does.
    pub fn comma(&mut self, v: Cell) -> Result<UCell, Error> {
        let here = self.here();
        if here + CELL > self.layout.dict + self.layout.dict_size {
            return Err(Error::DictionaryFull);
        }
        self.store(here, v)?;
        self.set_sys(SYS_HERE, (here + CELL) as Cell)?;
        Ok(here)
    }

    /// Compile a thread of execution tokens and return its body address.
    /// The caller is responsible for ending it with [`Prim::Exit`].
    pub fn compile(&mut self, xts: &[Cell]) -> Result<UCell, Error> {
        let body = self.here();
        for xt in xts {
            self.comma(*xt)?;
        }
        Ok(body)
    }

    // ---- stacks ----------------------------------------------------------

    pub fn push(&mut self, v: Cell) -> Result<(), Error> {
        if self.sp < self.layout.data_stack + CELL {
            return Err(Error::DataStackOverflow);
        }
        self.sp -= CELL;
        let sp = self.sp;
        self.store(sp, v)
    }

    pub fn pop(&mut self) -> Result<Cell, Error> {
        if self.sp >= self.layout.data_stack_top() {
            return Err(Error::DataStackUnderflow);
        }
        let v = self.fetch(self.sp)?;
        self.sp += CELL;
        Ok(v)
    }

    pub fn rpush(&mut self, v: Cell) -> Result<(), Error> {
        if self.rp < self.layout.return_stack + CELL {
            return Err(Error::ReturnStackOverflow);
        }
        self.rp -= CELL;
        let rp = self.rp;
        self.store(rp, v)
    }

    pub fn rpop(&mut self) -> Result<Cell, Error> {
        if self.rp >= self.layout.return_stack_top() {
            return Err(Error::ReturnStackUnderflow);
        }
        let v = self.fetch(self.rp)?;
        self.rp += CELL;
        Ok(v)
    }

    pub fn sp(&self) -> UCell {
        self.sp
    }

    pub fn rp(&self) -> UCell {
        self.rp
    }

    pub fn ip(&self) -> UCell {
        self.ip
    }

    pub fn depth(&self) -> UCell {
        (self.layout.data_stack_top() - self.sp) / CELL
    }

    /// The data stack, bottom first and top last.
    pub fn stack(&self) -> Vec<Cell> {
        // The stack grows down, so the first cell pushed sits at the highest
        // address: walking down from the top yields bottom first, top last.
        let mut out = Vec::new();
        let mut a = self.layout.data_stack_top();
        while a > self.sp {
            a -= CELL;
            out.push(self.fetch(a).unwrap_or(0));
        }
        out
    }

    /// The return stack, bottom first and top last.
    pub fn rstack(&self) -> Vec<Cell> {
        let mut out = Vec::new();
        let mut a = self.layout.return_stack_top();
        while a > self.rp {
            a -= CELL;
            out.push(self.fetch(a).unwrap_or(0));
        }
        out
    }

    // ---- snapshots -------------------------------------------------------

    /// The whole machine as bytes: memory, the four registers, the run flag,
    /// and the input and output buffers. Restoring it and stepping on must
    /// give exactly what stepping on from here would have given; that is the
    /// property deterministic simulation testing replays from.
    pub fn snapshot(&self) -> Vec<u8> {
        let mut b = Vec::with_capacity(self.mem.len() + self.input.len() + self.output.len() + 40);
        b.extend_from_slice(SNAPSHOT_MAGIC);
        b.extend_from_slice(&self.layout.end.to_le_bytes());
        b.extend_from_slice(&self.mem);
        for r in [self.sp, self.rp, self.ip, self.rp_floor] {
            b.extend_from_slice(&r.to_le_bytes());
        }
        b.push(self.running as u8);
        b.extend_from_slice(&(self.in_pos as u32).to_le_bytes());
        for buf in [&self.input, &self.output] {
            b.extend_from_slice(&(buf.len() as u32).to_le_bytes());
            b.extend_from_slice(buf);
        }
        b
    }

    /// Put back a [`Vm::snapshot`] taken from a kernel with the same layout.
    pub fn restore(&mut self, bytes: &[u8]) -> Result<(), Error> {
        let mut r = Reader { b: bytes, at: 0 };
        if r.take(SNAPSHOT_MAGIC.len())? != SNAPSHOT_MAGIC || r.u32()? != self.layout.end {
            return Err(Error::BadSnapshot);
        }
        let mem = r.take(self.mem.len())?.to_vec();
        let (sp, rp, ip, rp_floor) = (r.u32()?, r.u32()?, r.u32()?, r.u32()?);
        let running = r.take(1)?[0] != 0;
        let in_pos = r.u32()? as usize;
        let n = r.u32()? as usize;
        let input = r.take(n)?.to_vec();
        let n = r.u32()? as usize;
        let output = r.take(n)?.to_vec();
        if r.at != bytes.len() || in_pos > input.len() {
            return Err(Error::BadSnapshot);
        }
        self.mem = mem;
        (self.sp, self.rp, self.ip, self.rp_floor) = (sp, rp, ip, rp_floor);
        self.running = running;
        (self.input, self.in_pos, self.output) = (input, in_pos, output);
        Ok(())
    }

    /// FNV-1a over [`Vm::snapshot`]: two kernels with equal fingerprints are,
    /// to within a hash collision, in the same state.
    pub fn fingerprint(&self) -> u64 {
        self.snapshot()
            .iter()
            .fold(0xcbf2_9ce4_8422_2325u64, |h, &b| {
                (h ^ b as u64).wrapping_mul(0x0000_0100_0000_01b3)
            })
    }

    // ---- input and output ------------------------------------------------

    pub fn set_input(&mut self, bytes: &[u8]) {
        self.input = bytes.to_vec();
        self.in_pos = 0;
    }

    pub fn output(&self) -> &[u8] {
        &self.output
    }

    pub fn output_string(&self) -> String {
        String::from_utf8_lossy(&self.output).into_owned()
    }

    pub fn take_output(&mut self) -> Vec<u8> {
        core::mem::take(&mut self.output)
    }

    // ---- the inner interpreter -------------------------------------------

    /// Execute one execution token. A primitive runs in place; any other xt is
    /// a colon definition, so the current ip goes on the return stack.
    pub fn execute_xt(&mut self, xt: Cell) -> Result<(), Error> {
        match Prim::from_xt(xt) {
            Some(p) => self.do_prim(p),
            None => {
                let ip = self.ip as Cell;
                self.rpush(ip)?;
                self.ip = xt as UCell;
                Ok(())
            }
        }
    }

    /// NEXT: fetch the token at ip, advance ip, execute.
    pub fn step(&mut self) -> Result<(), Error> {
        let xt = self.fetch(self.ip)?;
        self.ip += CELL;
        self.execute_xt(xt)
    }

    /// Start a run of the thread at `body` without executing anything, so a
    /// host can drive it one [`Vm::step`] at a time. [`Vm::run`] is `begin`
    /// followed by stepping until the thread's final `exit`.
    pub fn begin(&mut self, body: UCell) {
        self.ip = body;
        self.rp_floor = self.rp;
        self.running = true;
    }

    /// Whether the run started by [`Vm::begin`] has not yet reached its final
    /// `exit`. An error leaves it set: the run did not finish, it stopped.
    pub fn running(&self) -> bool {
        self.running
    }

    /// Run the thread at `body` until its final `exit`, and return the number
    /// of tokens executed. `max_steps` bounds a runaway loop.
    pub fn run(&mut self, body: UCell, max_steps: u64) -> Result<u64, Error> {
        self.begin(body);
        let mut n = 0u64;
        while self.running {
            if n >= max_steps {
                self.running = false;
                return Err(Error::StepLimit);
            }
            self.step()?;
            n += 1;
        }
        Ok(n)
    }

    fn do_prim(&mut self, p: Prim) -> Result<(), Error> {
        use Prim::*;
        match p {
            // ( a-addr -- x )
            Fetch => {
                let a = self.pop()? as UCell;
                let v = self.fetch(a)?;
                self.push(v)
            }
            // ( x a-addr -- )
            Store => {
                let a = self.pop()? as UCell;
                let x = self.pop()?;
                self.store(a, x)
            }
            // ( -- a-addr ) the address holding the former top of stack, so
            // that `sp@ @` is `dup`.
            SpFetch => {
                let a = self.sp as Cell;
                self.push(a)
            }
            // ( -- a-addr )
            RpFetch => {
                let a = self.rp as Cell;
                self.push(a)
            }
            // ( x -- flag )
            ZeroEquals => {
                let x = self.pop()?;
                self.push(if x == 0 { TRUE } else { FALSE })
            }
            // ( n1 n2 -- n3 ) wrapping, as a fixed-width cell does
            Plus => {
                let b = self.pop()?;
                let a = self.pop()?;
                self.push(a.wrapping_add(b))
            }
            // ( x1 x2 -- x3 ) the one logical primitive; and, or, invert and
            // negate are frames words derived from it.
            Nand => {
                let b = self.pop()?;
                let a = self.pop()?;
                self.push(!(a & b))
            }
            // ( -- ) return to the caller, or stop if this thread began the run
            Exit => {
                if self.rp >= self.rp_floor {
                    self.running = false;
                } else {
                    let ip = self.rpop()? as UCell;
                    self.ip = ip;
                }
                Ok(())
            }
            // ( -- char ) -1 when the input is exhausted
            Key => {
                let c = if self.in_pos < self.input.len() {
                    let b = self.input[self.in_pos];
                    self.in_pos += 1;
                    b as Cell
                } else {
                    -1
                };
                self.push(c)
            }
            // ( char -- )
            Emit => {
                let c = self.pop()?;
                self.output.push(c as u8);
                Ok(())
            }
            // ( xt -- )
            Execute => {
                let xt = self.pop()?;
                self.execute_xt(xt)
            }
            // ( u1 u2 -- ud-lo ud-hi )
            UmStar => {
                let b = self.pop()? as UCell as u64;
                let a = self.pop()? as UCell as u64;
                let prod = a * b;
                self.push(prod as UCell as Cell)?;
                self.push((prod >> 32) as UCell as Cell)
            }
            // ( ud-lo ud-hi u -- u-rem u-quot )
            UmSlashMod => {
                let u = self.pop()? as UCell as u64;
                if u == 0 {
                    return Err(Error::DivideByZero);
                }
                let hi = self.pop()? as UCell as u64;
                let lo = self.pop()? as UCell as u64;
                let d = (hi << 32) | lo;
                let q = d / u;
                if q > UCell::MAX as u64 {
                    return Err(Error::QuotientOverflow);
                }
                self.push((d % u) as UCell as Cell)?;
                self.push(q as UCell as Cell)
            }
        }
    }
}

const SNAPSHOT_MAGIC: &[u8] = b"KEELSNAP1";

struct Reader<'a> {
    b: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8], Error> {
        let end = self.at.checked_add(n).ok_or(Error::BadSnapshot)?;
        let s = self.b.get(self.at..end).ok_or(Error::BadSnapshot)?;
        self.at = end;
        Ok(s)
    }

    fn u32(&mut self) -> Result<u32, Error> {
        let mut w = [0u8; 4];
        w.copy_from_slice(self.take(4)?);
        Ok(u32::from_le_bytes(w))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn r_k_01_exactly_thirteen_primitives_in_spec_order() {
        assert_eq!(Prim::COUNT, 13);
        assert_eq!(PRIM_NAMES.len(), 13);
        assert_eq!(
            PRIM_NAMES.to_vec(),
            vec![
                "@", "!", "sp@", "rp@", "0=", "+", "nand", "exit", "key", "emit", "execute", "um*",
                "um/mod"
            ]
        );
        for (i, p) in Prim::all().iter().enumerate() {
            assert_eq!(p.xt(), i as Cell);
            assert_eq!(p.name(), PRIM_NAMES[i]);
            assert_eq!(Prim::by_name(PRIM_NAMES[i]), Some(*p));
        }
        assert_eq!(Prim::from_xt(13), None);
    }

    #[test]
    fn r_k_03_cell_is_32_bit() {
        assert_eq!(core::mem::size_of::<Cell>() * 8, 32);
        assert_eq!(CELL, 4);
    }

    #[test]
    fn dup_is_sp_fetch_then_fetch() {
        // experiment 001 derives dup from `sp@ @`; the kernel must make that work.
        let mut vm = Vm::default();
        vm.push(42).unwrap();
        let body = vm
            .compile(&[Prim::SpFetch.xt(), Prim::Fetch.xt(), Prim::Exit.xt()])
            .unwrap();
        vm.run(body, 100).unwrap();
        assert_eq!(vm.stack(), vec![42, 42]);
    }

    #[test]
    fn colon_definition_nests_and_exits() {
        let mut vm = Vm::default();
        // inner: ( a b -- a+b )
        let inner = vm.compile(&[Prim::Plus.xt(), Prim::Exit.xt()]).unwrap();
        // outer: call inner twice
        let outer = vm
            .compile(&[inner as Cell, inner as Cell, Prim::Exit.xt()])
            .unwrap();
        vm.push(1).unwrap();
        vm.push(2).unwrap();
        vm.push(3).unwrap();
        vm.run(outer, 100).unwrap();
        assert_eq!(vm.stack(), vec![6]);
        assert_eq!(
            vm.rp(),
            vm.layout.return_stack_top(),
            "return stack unwound"
        );
    }
}
