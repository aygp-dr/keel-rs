//! wasm-bindgen shim exposing the keel to a JavaScript host.
//!
//! R-H-02 asks the wasm keel to export `new`, `interpret`, `push`, `pop` and
//! `stack`. Four of the five are here. `interpret` takes Forth *text*, which
//! needs the outer interpreter — a `frames` word written in Forth on top of
//! this kernel — so it arrives at M4 and is deliberately absent rather than
//! stubbed. Until then a host drives the kernel with `run`.

use keel::{Cell, Layout, Prim, UCell, Vm};
use wasm_bindgen::prelude::*;

/// Default ceiling on tokens executed by one `run`, so a runaway thread cannot
/// hang the host.
const DEFAULT_STEP_LIMIT: u64 = 10_000_000;

#[wasm_bindgen]
pub struct Keel {
    vm: Vm,
    step_limit: u64,
}

#[wasm_bindgen]
impl Keel {
    /// A kernel with the default memory map.
    #[wasm_bindgen(constructor)]
    pub fn new() -> Keel {
        Keel {
            vm: Vm::new(Layout::default()),
            step_limit: DEFAULT_STEP_LIMIT,
        }
    }

    /// Push one cell.
    pub fn push(&mut self, value: Cell) -> Result<(), JsValue> {
        self.vm.push(value).map_err(err)
    }

    /// Pop one cell.
    pub fn pop(&mut self) -> Result<Cell, JsValue> {
        self.vm.pop().map_err(err)
    }

    /// The data stack, bottom first and top last.
    pub fn stack(&self) -> Vec<Cell> {
        self.vm.stack()
    }

    /// How many cells are on the data stack.
    pub fn depth(&self) -> UCell {
        self.vm.depth()
    }

    /// Compile a thread of execution tokens and return its body address.
    pub fn compile(&mut self, xts: Vec<Cell>) -> Result<UCell, JsValue> {
        self.vm.compile(&xts).map_err(err)
    }

    /// Run the thread at `body`, returning how many tokens executed.
    pub fn run(&mut self, body: UCell) -> Result<u32, JsValue> {
        let limit = self.step_limit;
        self.vm.run(body, limit).map(|n| n as u32).map_err(err)
    }

    /// Bytes that `key` will read.
    #[wasm_bindgen(js_name = setInput)]
    pub fn set_input(&mut self, text: &str) {
        self.vm.set_input(text.as_bytes());
    }

    /// Everything `emit` has written so far.
    pub fn output(&self) -> String {
        self.vm.output_string()
    }

    /// Clear the stacks and buffers; the dictionary is kept.
    pub fn reset(&mut self) {
        self.vm.reset();
    }

    /// The execution token of a primitive, by its Forth name.
    #[wasm_bindgen(js_name = primitive)]
    pub fn primitive(name: &str) -> Option<Cell> {
        Prim::by_name(name).map(|p| p.xt())
    }

    /// The thirteen primitive names, in spec order (R-K-01).
    #[wasm_bindgen(js_name = primitiveNames)]
    pub fn primitive_names() -> Vec<JsValue> {
        keel::PRIM_NAMES
            .iter()
            .map(|n| JsValue::from_str(n))
            .collect()
    }
}

impl Default for Keel {
    fn default() -> Self {
        Self::new()
    }
}

fn err(e: keel::Error) -> JsValue {
    JsValue::from_str(&e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn push_pop_and_stack_round_trip() {
        let mut k = Keel::new();
        k.push(2).unwrap();
        k.push(3).unwrap();
        assert_eq!(k.stack(), vec![2, 3]);
        assert_eq!(k.depth(), 2);
        assert_eq!(k.pop().unwrap(), 3);
        assert_eq!(k.stack(), vec![2]);
    }

    #[test]
    fn a_host_can_compile_and_run_a_thread() {
        let mut k = Keel::new();
        let plus = Keel::primitive("+").unwrap();
        let exit = Keel::primitive("exit").unwrap();
        let body = k.compile(vec![plus, exit]).unwrap();
        k.push(20).unwrap();
        k.push(22).unwrap();
        k.run(body).unwrap();
        assert_eq!(k.stack(), vec![42]);
    }

    #[test]
    fn emit_reaches_the_host_as_output() {
        let mut k = Keel::new();
        let emit = Keel::primitive("emit").unwrap();
        let exit = Keel::primitive("exit").unwrap();
        let body = k.compile(vec![emit, exit]).unwrap();
        k.push('k' as Cell).unwrap();
        k.run(body).unwrap();
        assert_eq!(k.output(), "k");
    }

    #[test]
    fn unknown_primitive_name_is_none() {
        // `dup` is a frames word, not a keel primitive.
        assert_eq!(Keel::primitive("dup"), None);
        assert_eq!(keel::PRIM_NAMES.len(), 13);
    }

    // The message a host sees for a failed call. Asserted on keel::Error
    // rather than on the JsValue it becomes, because wasm-bindgen's JsValue
    // only exists on a wasm target and panics when touched natively.
    #[test]
    fn errors_cross_the_boundary_as_messages() {
        assert_eq!(
            keel::Error::DataStackUnderflow.to_string(),
            "data stack underflow"
        );
        let mut k = Keel::new();
        assert!(k.vm.pop().is_err());
    }
}
