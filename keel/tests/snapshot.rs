//! Snapshots are what deterministic simulation testing replays from: a run
//! restored mid-way must finish exactly as the uninterrupted run did.

use keel::{Cell, Error, Prim, Vm};

fn xt(p: Prim) -> Cell {
    p.xt()
}

/// A small thread with a nested call, output and input, so every part of the
/// snapshot (memory, both stacks, ip, buffers) is in play.
fn setup() -> (Vm, u32) {
    let mut vm = Vm::default();
    let inner = vm.compile(&[xt(Prim::Plus), xt(Prim::Exit)]).unwrap();
    let body = vm
        .compile(&[
            xt(Prim::Key),
            xt(Prim::Emit),
            inner as Cell,
            xt(Prim::SpFetch),
            xt(Prim::Fetch),
            xt(Prim::UmStar),
            xt(Prim::Plus),
            xt(Prim::Exit),
        ])
        .unwrap();
    vm.set_input(b"k\xff");
    for v in [7, 11, 13] {
        vm.push(v).unwrap();
    }
    (vm, body)
}

fn finish(vm: &mut Vm) -> u64 {
    while vm.running() {
        vm.step().unwrap();
    }
    vm.fingerprint()
}

#[test]
fn restoring_mid_run_finishes_as_the_straight_run_does() {
    let (mut straight, body) = setup();
    straight.begin(body);
    let expected = finish(&mut straight);

    for cut in 0..6 {
        let (mut vm, body) = setup();
        vm.begin(body);
        for _ in 0..cut {
            vm.step().unwrap();
        }
        let snap = vm.snapshot();
        // Run the original on, then rewind it to the snapshot.
        finish(&mut vm);
        vm.restore(&snap).unwrap();
        assert_eq!(finish(&mut vm), expected, "restored at step {cut}");

        // A fresh kernel given only the snapshot gets there too.
        let mut other = Vm::default();
        other.restore(&snap).unwrap();
        assert_eq!(finish(&mut other), expected, "fresh kernel at step {cut}");
    }
}

#[test]
fn the_same_inputs_give_the_same_fingerprint() {
    let (mut a, body) = setup();
    let (mut b, _) = setup();
    a.begin(body);
    b.begin(body);
    assert_eq!(finish(&mut a), finish(&mut b));
}

#[test]
fn a_different_state_gives_a_different_fingerprint() {
    let (a, _) = setup();
    let (mut b, _) = setup();
    b.push(1).unwrap();
    assert_ne!(a.fingerprint(), b.fingerprint());
}

#[test]
fn a_damaged_snapshot_is_refused_and_leaves_the_kernel_alone() {
    let (mut vm, _) = setup();
    let before = vm.fingerprint();
    let snap = vm.snapshot();
    assert_eq!(vm.restore(&snap[..snap.len() - 1]), Err(Error::BadSnapshot));
    let mut bad = snap.clone();
    bad[0] ^= 1;
    assert_eq!(vm.restore(&bad), Err(Error::BadSnapshot));
    let mut long = snap.clone();
    long.push(0);
    assert_eq!(vm.restore(&long), Err(Error::BadSnapshot));
    assert_eq!(vm.fingerprint(), before);
}
