//! Property tests with Hegel (hegeltest), after oxidecomputer/iddqd's pattern:
//! the kernel against a plain model, every step, with shrinking.
//!
//! 1. Each arithmetic primitive agrees with exact integer arithmetic.
//! 2. A state machine of pushes, pops and primitive runs keeps the VM's data
//!    stack equal to a `Vec` model, errors included.
//!
//! The model mirrors keel's observed error behaviour: operands are popped one
//! at a time, so an error can leave partial effects (an underflowing `+` with
//! one item consumes it; `um/mod` by zero pops only the divisor; a quotient
//! overflow pops all three and pushes nothing; `um*` near a full stack can
//! push its low cell and then overflow).

use hegel::{generators as gs, TestCase};
use keel::{Cell, Error, Prim, UCell, Vm, FALSE, TRUE};

const ARITH: [Prim; 5] = [
    Prim::ZeroEquals,
    Prim::Plus,
    Prim::Nand,
    Prim::UmStar,
    Prim::UmSlashMod,
];

fn run_one(initial: &[Cell], p: Prim) -> Result<Vec<Cell>, Error> {
    let mut vm = Vm::default();
    for v in initial {
        vm.push(*v)?;
    }
    let body = vm.compile(&[p.xt(), Prim::Exit.xt()])?;
    vm.run(body, 100)?;
    Ok(vm.stack())
}

#[hegel::test(test_cases = 1000)]
fn arithmetic_agrees_with_exact_integers(tc: TestCase) {
    let a: Cell = tc.draw(gs::integers::<i32>());
    let b: Cell = tc.draw(gs::integers::<i32>());
    let (ua, ub) = (a as UCell as u64, b as UCell as u64);

    assert_eq!(
        run_one(&[a], Prim::ZeroEquals),
        Ok(vec![if a == 0 { TRUE } else { FALSE }])
    );
    assert_eq!(
        run_one(&[a, b], Prim::Plus),
        Ok(vec![((ua + ub) as UCell) as Cell])
    );
    assert_eq!(run_one(&[a, b], Prim::Nand), Ok(vec![!(a & b)]));
    let prod = ua * ub;
    assert_eq!(
        run_one(&[a, b], Prim::UmStar),
        Ok(vec![prod as UCell as Cell, (prod >> 32) as UCell as Cell])
    );

    // um/mod over a double cell: lo = a, hi = b, divisor u
    let u: Cell = tc.draw(gs::integers::<i32>());
    let uu = u as UCell as u64;
    let d = (ub << 32) | ua;
    let got = run_one(&[a, b, u], Prim::UmSlashMod);
    if uu == 0 {
        assert_eq!(got, Err(Error::DivideByZero));
    } else if d / uu > UCell::MAX as u64 {
        assert_eq!(got, Err(Error::QuotientOverflow));
    } else {
        assert_eq!(
            got,
            Ok(vec![(d % uu) as UCell as Cell, (d / uu) as UCell as Cell])
        );
    }
}

/// The data stack as a plain vector with keel's capacity and pop order.
struct Model {
    ds: Vec<Cell>,
    cap: usize,
}

impl Model {
    fn pop(&mut self) -> Result<Cell, Error> {
        self.ds.pop().ok_or(Error::DataStackUnderflow)
    }
    fn push(&mut self, v: Cell) -> Result<(), Error> {
        if self.ds.len() >= self.cap {
            return Err(Error::DataStackOverflow);
        }
        self.ds.push(v);
        Ok(())
    }
    fn apply(&mut self, p: Prim) -> Result<(), Error> {
        match p {
            Prim::ZeroEquals => {
                let x = self.pop()?;
                self.push(if x == 0 { TRUE } else { FALSE })
            }
            Prim::Plus => {
                let b = self.pop()?;
                let a = self.pop()?;
                self.push(a.wrapping_add(b))
            }
            Prim::Nand => {
                let b = self.pop()?;
                let a = self.pop()?;
                self.push(!(a & b))
            }
            Prim::UmStar => {
                let b = self.pop()? as UCell as u64;
                let a = self.pop()? as UCell as u64;
                let prod = a * b;
                self.push(prod as UCell as Cell)?;
                self.push((prod >> 32) as UCell as Cell)
            }
            Prim::UmSlashMod => {
                let u = self.pop()? as UCell as u64;
                if u == 0 {
                    return Err(Error::DivideByZero);
                }
                let hi = self.pop()? as UCell as u64;
                let lo = self.pop()? as UCell as u64;
                let d = (hi << 32) | lo;
                if d / u > UCell::MAX as u64 {
                    return Err(Error::QuotientOverflow);
                }
                self.push((d % u) as UCell as Cell)?;
                self.push((d / u) as UCell as Cell)
            }
            _ => unreachable!("only arithmetic primitives are modelled"),
        }
    }
}

struct StackMachine {
    vm: Vm,
    model: Model,
    /// One compiled thread per arithmetic primitive, compiled once so the
    /// dictionary does not fill up over a long run.
    bodies: Vec<UCell>,
}

impl StackMachine {
    fn new() -> Self {
        let mut probe = Vm::default();
        let mut cap = 0;
        while probe.push(0).is_ok() {
            cap += 1;
        }
        let mut vm = Vm::default();
        let bodies = ARITH
            .iter()
            .map(|p| vm.compile(&[p.xt(), Prim::Exit.xt()]).expect("compile"))
            .collect();
        StackMachine {
            vm,
            model: Model {
                ds: Vec::new(),
                cap,
            },
            bodies,
        }
    }
}

#[hegel::state_machine]
impl StackMachine {
    #[rule]
    fn push(&mut self, tc: TestCase) {
        let v: Cell = tc.draw(gs::integers::<i32>());
        assert_eq!(self.vm.push(v), self.model.push(v));
    }

    #[rule]
    fn pop(&mut self, _: TestCase) {
        assert_eq!(self.vm.pop(), self.model.pop());
    }

    #[rule]
    fn run_primitive(&mut self, tc: TestCase) {
        let i = tc.draw(gs::integers::<usize>().max_value(ARITH.len() - 1));
        let got = self.vm.run(self.bodies[i], 100).map(|_| ());
        assert_eq!(got, self.model.apply(ARITH[i]), "{}", ARITH[i].name());
    }

    // always_run: checked after every rule, not sampled (iddqd's AGENTS.md).
    #[invariant(always_run)]
    fn stack_matches_model(&mut self, _: TestCase) {
        assert_eq!(self.vm.stack(), self.model.ds);
        assert_eq!(self.vm.depth() as usize, self.model.ds.len());
    }
}

#[hegel::test(test_cases = 300)]
fn stack_agrees_with_model(tc: TestCase) {
    hegel::stateful::machine(StackMachine::new()).run(tc);
}
