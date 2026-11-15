//! Per-primitive vectors for R-K-01 and region boundaries for R-K-04.
//!
//! Each vector is (initial stack, primitive, expected stack), so a failure
//! names the one primitive that broke.

use keel::{Cell, Error, Layout, Prim, Vm, CELL, FALSE, SYS_BASE, SYS_HERE, SYS_HP, TRUE};

/// Run one primitive over a starting stack and return the resulting stack.
fn apply(initial: &[Cell], p: Prim) -> Result<Vec<Cell>, Error> {
    let mut vm = Vm::default();
    for v in initial {
        vm.push(*v)?;
    }
    let body = vm.compile(&[p.xt(), Prim::Exit.xt()])?;
    vm.run(body, 100)?;
    Ok(vm.stack())
}

fn check(initial: &[Cell], p: Prim, expected: &[Cell]) {
    match apply(initial, p) {
        Ok(got) => assert_eq!(got, expected.to_vec(), "{} on {:?}", p.name(), initial),
        Err(e) => panic!("{} on {:?} failed: {e}", p.name(), initial),
    }
}

#[test]
fn plus() {
    check(&[2, 3], Prim::Plus, &[5]);
    check(&[-1, 1], Prim::Plus, &[0]);
    check(&[0, 0], Prim::Plus, &[0]);
    // a fixed-width cell wraps rather than panicking
    check(&[Cell::MAX, 1], Prim::Plus, &[Cell::MIN]);
}

#[test]
fn zero_equals() {
    check(&[0], Prim::ZeroEquals, &[TRUE]);
    check(&[1], Prim::ZeroEquals, &[FALSE]);
    check(&[-1], Prim::ZeroEquals, &[FALSE]);
    // 0= twice is a boolean normaliser
    assert_eq!(
        apply(&[7], Prim::ZeroEquals)
            .and_then(|s| apply(&s, Prim::ZeroEquals))
            .unwrap(),
        vec![TRUE]
    );
}

#[test]
fn nand_is_the_only_logic_primitive() {
    check(&[0, 0], Prim::Nand, &[-1]);
    check(&[-1, -1], Prim::Nand, &[0]);
    check(&[0xFF, 0x0F], Prim::Nand, &[!0x0F]);
    // invert x = x nand x
    check(&[5, 5], Prim::Nand, &[!5]);
    // and: frames derives it as `nand invert`, i.e. nand then nand with itself
    let once = apply(&[0b1100, 0b1010], Prim::Nand).unwrap();
    let twice = apply(&[once[0], once[0]], Prim::Nand).unwrap();
    assert_eq!(twice, vec![0b1000]);
}

#[test]
fn fetch_and_store() {
    let mut vm = Vm::default();
    let addr = vm.layout.dict + 64 * CELL;
    vm.push(1234).unwrap();
    vm.push(addr as Cell).unwrap();
    let body = vm.compile(&[Prim::Store.xt(), Prim::Exit.xt()]).unwrap();
    vm.run(body, 100).unwrap();
    assert_eq!(vm.stack(), Vec::<Cell>::new(), "! consumes both cells");
    assert_eq!(vm.fetch(addr).unwrap(), 1234);

    vm.push(addr as Cell).unwrap();
    let body = vm.compile(&[Prim::Fetch.xt(), Prim::Exit.xt()]).unwrap();
    vm.run(body, 100).unwrap();
    assert_eq!(vm.stack(), vec![1234]);
}

#[test]
fn unaligned_and_out_of_range_access_is_an_error() {
    let vm = Vm::default();
    let odd = vm.layout.dict + 1;
    assert_eq!(vm.fetch(odd), Err(Error::Unaligned(odd)));
    let past = vm.layout.end;
    assert_eq!(vm.fetch(past), Err(Error::OutOfRange(past)));
}

#[test]
fn sp_fetch_and_rp_fetch_report_the_pointers() {
    let mut vm = Vm::default();
    vm.push(9).unwrap();
    let sp_before = vm.sp();
    let body = vm.compile(&[Prim::SpFetch.xt(), Prim::Exit.xt()]).unwrap();
    vm.run(body, 100).unwrap();
    assert_eq!(vm.stack(), vec![9, sp_before as Cell]);
    // the address sp@ pushed holds the former top of stack
    assert_eq!(vm.fetch(sp_before).unwrap(), 9);

    let mut vm = Vm::default();
    let body = vm.compile(&[Prim::RpFetch.xt(), Prim::Exit.xt()]).unwrap();
    vm.run(body, 100).unwrap();
    // inside a run the return stack holds nothing yet, so rp is at its top
    assert_eq!(vm.stack(), vec![vm.layout.return_stack_top() as Cell]);
}

#[test]
fn key_and_emit_move_bytes() {
    let mut vm = Vm::default();
    vm.set_input(b"Hi");
    let body = vm
        .compile(&[
            Prim::Key.xt(),
            Prim::Emit.xt(),
            Prim::Key.xt(),
            Prim::Emit.xt(),
            Prim::Key.xt(), // input exhausted
            Prim::Exit.xt(),
        ])
        .unwrap();
    vm.run(body, 100).unwrap();
    assert_eq!(vm.output_string(), "Hi");
    assert_eq!(vm.stack(), vec![-1], "key gives -1 at end of input");
}

#[test]
fn execute_runs_a_token_from_the_stack() {
    let mut vm = Vm::default();
    vm.push(20).unwrap();
    vm.push(22).unwrap();
    vm.push(Prim::Plus.xt()).unwrap();
    let body = vm.compile(&[Prim::Execute.xt(), Prim::Exit.xt()]).unwrap();
    vm.run(body, 100).unwrap();
    assert_eq!(vm.stack(), vec![42]);
}

#[test]
fn execute_runs_a_colon_definition_from_the_stack() {
    let mut vm = Vm::default();
    let double = vm
        .compile(&[
            Prim::SpFetch.xt(),
            Prim::Fetch.xt(),
            Prim::Plus.xt(),
            Prim::Exit.xt(),
        ])
        .unwrap();
    vm.push(21).unwrap();
    vm.push(double as Cell).unwrap();
    let body = vm.compile(&[Prim::Execute.xt(), Prim::Exit.xt()]).unwrap();
    vm.run(body, 100).unwrap();
    assert_eq!(vm.stack(), vec![42]);
}

#[test]
fn um_star_produces_a_double_cell() {
    // ( u1 u2 -- lo hi ), high cell on top
    check(&[0, 0], Prim::UmStar, &[0, 0]);
    check(&[6, 7], Prim::UmStar, &[42, 0]);
    // 65536 * 65536 = 2^32: low cell zero, high cell one
    check(&[1 << 16, 1 << 16], Prim::UmStar, &[0, 1]);
    // operands are unsigned: -1 is 0xFFFFFFFF
    check(&[-1, 2], Prim::UmStar, &[-2, 1]);
}

#[test]
fn um_slash_mod_divides_a_double_cell() {
    // ( ud-lo ud-hi u -- rem quot ), quotient on top
    check(&[42, 0, 6], Prim::UmSlashMod, &[0, 7]);
    check(&[43, 0, 6], Prim::UmSlashMod, &[1, 7]);
    // 2^32 / 2 = 2^31, which fits as an unsigned cell
    check(&[0, 1, 2], Prim::UmSlashMod, &[0, i32::MIN]);
    assert_eq!(
        apply(&[1, 0, 0], Prim::UmSlashMod),
        Err(Error::DivideByZero)
    );
    // 2^32 / 1 does not fit in one cell
    assert_eq!(
        apply(&[0, 1, 1], Prim::UmSlashMod),
        Err(Error::QuotientOverflow)
    );
}

#[test]
fn stack_errors_are_reported_not_wrapped() {
    assert_eq!(apply(&[], Prim::Plus), Err(Error::DataStackUnderflow));
    assert_eq!(apply(&[1], Prim::Plus), Err(Error::DataStackUnderflow));
    let mut vm = Vm::new(Layout::new(64, 1024, 1024, 2 * CELL, 2 * CELL));
    vm.push(1).unwrap();
    vm.push(2).unwrap();
    assert_eq!(vm.push(3), Err(Error::DataStackOverflow));
}

#[test]
fn a_runaway_thread_hits_the_step_limit() {
    let mut vm = Vm::default();
    let body = vm.here();
    // a thread that calls itself: no exit is ever reached
    vm.compile(&[body as Cell, Prim::Exit.xt()]).unwrap();
    assert_eq!(vm.run(body, 50), Err(Error::StepLimit));
}

// ---- R-K-04: one linear memory, laid out as the memory map ---------------

#[test]
fn r_k_04_regions_are_ordered_aligned_and_contiguous() {
    let layout = Layout::default();
    let b = layout.boundaries();
    for w in b.windows(2) {
        assert!(w[0] < w[1], "regions ascend: {:?}", b);
    }
    for x in b {
        assert_eq!(x % CELL, 0, "boundary {x} is cell-aligned");
    }
    // memory-map order: sys, tib, dictionary, from-space, to-space, data, return
    assert_eq!(layout.sys, 0);
    assert_eq!(layout.tib, keel::SYS_CELLS * CELL);
    assert_eq!(layout.dict, layout.tib + layout.tib_size);
    assert_eq!(layout.from_space, layout.dict + layout.dict_size);
    assert_eq!(layout.to_space, layout.from_space + layout.semispace_size);
    assert_eq!(layout.data_stack, layout.to_space + layout.semispace_size);
    assert_eq!(
        layout.return_stack,
        layout.data_stack + layout.data_stack_size
    );
    assert_eq!(layout.end, layout.return_stack + layout.return_stack_size);
    // the two semispaces are the same size, as a copying collector needs
    assert_eq!(layout.semispace_size, layout.to_space - layout.from_space);
    assert_eq!(layout.semispace_size, layout.data_stack - layout.to_space);

    let vm = Vm::new(layout);
    assert_eq!(vm.mem.len(), layout.end as usize, "memory is one region");
}

#[test]
fn r_k_04_both_stacks_grow_down() {
    let mut vm = Vm::default();
    let sp0 = vm.sp();
    vm.push(1).unwrap();
    assert!(vm.sp() < sp0, "data stack grows down");
    assert_eq!(vm.depth(), 1);
    let rp0 = vm.rp();
    vm.rpush(1).unwrap();
    assert!(vm.rp() < rp0, "return stack grows down");
    // the stacks live in disjoint regions
    assert!(vm.sp() >= vm.layout.data_stack && vm.sp() < vm.layout.data_stack_top());
    assert!(vm.rp() >= vm.layout.return_stack && vm.rp() < vm.layout.return_stack_top());
}

#[test]
fn system_variables_start_where_the_map_says() {
    let vm = Vm::default();
    assert_eq!(vm.sys(SYS_HERE).unwrap() as u32, vm.layout.dict);
    assert_eq!(vm.sys(SYS_HP).unwrap() as u32, vm.layout.from_space);
    assert_eq!(vm.sys(SYS_BASE).unwrap(), 10);
    assert_eq!(vm.here(), vm.layout.dict);
}

#[test]
fn comma_advances_here_and_stays_in_the_dictionary() {
    let mut vm = Vm::default();
    let start = vm.here();
    let at = vm.comma(7).unwrap();
    assert_eq!(at, start);
    assert_eq!(vm.here(), start + CELL);
    assert_eq!(vm.fetch(start).unwrap(), 7);

    let mut small = Vm::new(Layout::new(64, 2 * CELL, 64, 64, 64));
    small.comma(1).unwrap();
    small.comma(2).unwrap();
    assert_eq!(small.comma(3), Err(Error::DictionaryFull));
}
