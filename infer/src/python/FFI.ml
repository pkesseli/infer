(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd
module L = Logging
module T = Textual

type pyConstant =
  | PYCBool of bool
  | PYCInt of int64
  | PYCString of string
  | PYCTuple of pyConstant array
  | PYCCode of pyCode
  | PYCNone

and pyCode =
  { co_name: string
  ; co_filename: string
  ; (* TODO we don't use it really at the moment, just keeping it around not to
       forget about it *)
    co_flags: int
  ; co_cellvars: string array
  ; co_freevars: string array
  ; co_names: string array
  ; co_varnames: string array
  ; co_nlocals: int
  ; co_argcount: int
  ; co_firstlineno: int
  ; co_posonlyargcount: int
  ; co_stacksize: int
  ; co_kwonlyargcount: int
  ; co_lnotab: char array
  ; co_consts: pyConstant array
  ; (* we don't keep co_code around, we use the front-end Instructions
       to get more info right away *)
    instructions: pyInstruction list }

and pyInstruction =
  { (* TODO: make opname static ? list all names somewhere *)
    opname: string
  ; opcode: int
  ; arg: int
  ; argval: pyConstant
  ; (* TODO: python provides argval, not sure we need it ? *)
    offset: int
  ; starts_line: int option
  ; is_jump_target: bool }
[@@deriving show, compare]

let die_invalid_field ~kind f obj =
  L.die ExternalError "Field %s in object %s is not a valid %s" f (Py.Object.to_string obj) kind


let read_field obj action f =
  match Py.Object.find_attr_string_opt obj f with
  | None ->
      L.die ExternalError "No field %s in object %s" f (Py.Object.to_string obj)
  | Some obj ->
      action f obj


let get_string f obj =
  if Py.String.check obj then Py.String.to_string obj else die_invalid_field ~kind:"string" f obj


let read_string f obj = read_field obj get_string f

let get_int f obj =
  if Py.Int.check obj then Py.Int.to_int obj else die_invalid_field ~kind:"int" f obj


let read_int f obj = read_field obj get_int f

let read_bool f obj =
  let action f obj =
    if Py.Bool.check obj then Py.Bool.to_bool obj else die_invalid_field ~kind:"bool" f obj
  in
  read_field obj action f


let read_symbol_array f obj =
  let action f obj =
    if Py.Tuple.check obj then Py.Tuple.to_array_map (get_string f) obj
    else die_invalid_field ~kind:"tuple" f obj
  in
  read_field obj action f


let read_char_array f obj =
  let action f obj =
    try Py.Bytes.to_bytes obj with Py.E _ -> die_invalid_field ~kind:"array of bytes" f obj
  in
  Core.Bytes.to_array @@ read_field obj action f


let rec new_py_constant obj =
  let ty = Py.Type.get obj in
  match ty with
  | Py.Type.Bool ->
      PYCBool (Py.Bool.to_bool obj)
  | Int | Long ->
      (* TODO: deal with big ints since python has arbitrary precision *)
      PYCInt (Py.Int.to_int64 obj)
  | None | Null ->
      PYCNone
  | Tuple ->
      PYCTuple (Py.Tuple.to_array_map new_py_constant obj)
  | Unicode ->
      let s = Py.String.to_string obj in
      PYCString s
  | Unknown ->
      PYCCode (new_py_code obj)
  | Callable | Capsule | Closure | Dict | Float | List | Module | Type | Bytes | Iter | Set ->
      L.die InternalError "[new_py_constant] unknown bytecode constant: %s" (Py.Type.name ty)


and new_py_code obj =
  let co_name = read_string "co_name" obj in
  let co_filename = read_string "co_filename" obj in
  let co_flags = read_int "co_flags" obj in
  let co_cellvars = read_symbol_array "co_cellvars" obj in
  let co_freevars = read_symbol_array "co_freevars" obj in
  let co_names = read_symbol_array "co_names" obj in
  let co_varnames = read_symbol_array "co_varnames" obj in
  let co_nlocals = read_int "co_nlocals" obj in
  let co_argcount = read_int "co_argcount" obj in
  let co_firstlineno = read_int "co_firstlineno" obj in
  let co_posonlyargcount = read_int "co_posonlyargcount" obj in
  let co_stacksize = read_int "co_stacksize" obj in
  let co_kwonlyargcount = read_int "co_kwonlyargcount" obj in
  let co_lnotab = read_char_array "co_lnotab" obj in
  let co_consts =
    let action f obj =
      if Py.Tuple.check obj then Py.Tuple.to_array_map new_py_constant obj
      else die_invalid_field ~kind:"array of constants" f obj
    in
    read_field obj action "co_consts"
  in
  (* TODO: this code is a simple function that takes the bytecode array
   * and turns it into a list of instructions. We might want to
   * replicate its job here, if speed gets in the way at some
   * point.
   * https://github.com/python/cpython/blob/main/Lib/dis.py#L337
   *
   * For now, I rely on calling Python to do the job for me:
   * The `pybc` module is an way to get/send data from/to python
   *)
  let code =
    {|
import dis, pybc
from pybc import input
l = list(dis.Bytecode(input))
pybc.output = l
|}
  in
  let m = Py.Import.add_module "pybc" in
  Py.Module.set m "input" obj ;
  let _none = Py.Run.eval ~start:Py.File code in
  let instructions = Py.Module.get m "output" in
  let instructions =
    if Py.List.check instructions then
      let l = Py.List.to_list instructions in
      List.map ~f:new_py_instruction l
    else die_invalid_field ~kind:"list of instructions" "co_code" obj
  in
  { co_name
  ; co_filename
  ; co_flags
  ; co_cellvars
  ; co_freevars
  ; co_names
  ; co_varnames
  ; co_nlocals
  ; co_argcount
  ; co_firstlineno
  ; co_posonlyargcount
  ; co_stacksize
  ; co_kwonlyargcount
  ; co_lnotab
  ; co_consts
  ; instructions }


and new_py_instruction obj =
  let opname = read_string "opname" obj in
  let opcode = read_int "opcode" obj in
  let opt = read_field obj (fun _ x -> x) "arg" in
  let arg = if Py.is_none opt then 0 else get_int "arg" opt in
  let argval =
    if Py.is_none opt then PYCNone
    else
      let opt = read_field obj (fun _ x -> x) "argval" in
      new_py_constant opt
  in
  let offset = read_int "offset" obj in
  let starts_line =
    let opt = read_field obj (fun _ x -> x) "starts_line" in
    if Py.is_none opt then None else Some (get_int "starts_line" opt)
  in
  let is_jump_target = read_bool "is_jump_target" obj in
  {opname; opcode; arg; argval; offset; starts_line; is_jump_target}


module Constant = struct
  type t = pyConstant =
    | PYCBool of bool
    | PYCInt of int64
    | PYCString of string
    | PYCTuple of pyConstant array
    | PYCCode of pyCode
    | PYCNone
  [@@deriving show, compare]

  let create obj = new_py_constant obj

  let rec to_exp = function
    | PYCBool b ->
        let b = if b then Z.one else Z.zero in
        let exp = T.(Exp.Const (Const.Int b)) in
        Some (exp, T.Typ.Int)
    | PYCInt i ->
        Some PyCommon.(mk_int i, pyInt)
    | PYCString s ->
        Some PyCommon.(mk_string s, pyString)
    | PYCNone ->
        let exp = T.(Exp.Const Const.Null) in
        Some (exp, T.Typ.Null)
    | PYCCode _ ->
        None
    | PYCTuple arr -> (
        let l = Array.to_list arr in
        let l = List.map ~f:(fun c -> to_exp c |> Option.map ~f:fst) l in
        match Option.all l with
        | None ->
            None
        | Some args ->
            let exp = T.Exp.Call {proc= PyCommon.python_tuple; args; kind= NonVirtual} in
            Some (exp, PyCommon.pyObject) )


  let as_code = function
    | PYCCode c ->
        Some c
    | PYCBool _ | PYCInt _ | PYCString _ | PYCTuple _ | PYCNone ->
        None


  let as_name = function
    | PYCString name ->
        Some name
    | PYCBool _ | PYCInt _ | PYCCode _ | PYCTuple _ | PYCNone ->
        None
end

module Code = struct
  type t = pyCode =
    { co_name: string
    ; co_filename: string
    ; co_flags: int
    ; co_cellvars: string array
    ; co_freevars: string array
    ; co_names: string array
    ; co_varnames: string array
    ; co_nlocals: int
    ; co_argcount: int
    ; co_firstlineno: int
    ; co_posonlyargcount: int
    ; co_stacksize: int
    ; co_kwonlyargcount: int
    ; co_lnotab: char array
    ; co_consts: pyConstant array
    ; instructions: pyInstruction list }
  [@@deriving show, compare]

  let create obj = new_py_code obj

  let is_closure {co_freevars; co_cellvars} =
    Array.length co_freevars + Array.length co_cellvars <> 0
end

module Instruction = struct
  type t = pyInstruction =
    { (* TODO: make opname static ? list all names somewhere ? *)
      opname: string
    ; opcode: int
    ; arg: int
    ; argval: pyConstant
    ; (* TODO: python provides argval, not sure we need it ... *)
      offset: int
    ; starts_line: int option
    ; is_jump_target: bool }
  [@@deriving show, compare]

  let create obj = new_py_instruction obj
end

let from_python_object obj =
  try
    let cst = new_py_constant obj in
    match cst with
    | PYCCode code ->
        code
    | _ ->
        L.die InternalError "[load_code] must always return a code object"
  with Py.E _ as e -> L.die ExternalError "[load_code] pyml exception: %s" (Exn.to_string e)


let from_string ~source ~filename =
  let pyobj = Py.Module.compile ~source ~filename Pytypes.File in
  from_python_object pyobj


let from_source filename =
  let source = Core.In_channel.read_all filename in
  from_string ~source ~filename


let from_bytecode filename =
  (* see https://peps.python.org/pep-0552/ *)
  let fp = Core.In_channel.create ~binary:true filename in
  let size = Int64.to_int_exn @@ Core.In_channel.length fp in
  if size <= 4 then L.die UserError "[from_bytecode] Not enough data in file %s" filename
  else
    let magic = Base.Bytes.create 4 in
    let read_magic = Core.In_channel.input fp ~buf:magic ~pos:0 ~len:4 in
    (* Check the magic word *)
    let mref = Base.Bytes.create 4 in
    Base.Bytes.set mref 0 (Char.of_int_exn 85) ;
    Base.Bytes.set mref 1 (Char.of_int_exn 13) ;
    Base.Bytes.set mref 2 (Char.of_int_exn 13) ;
    Base.Bytes.set mref 3 (Char.of_int_exn 10) ;
    let show_array = [%derive.show: bytes] in
    if read_magic <> 4 || not (Base.Bytes.equal magic mref) then
      L.die UserError "Invalid magic number for Python 3.8. Expected %s but got %s"
        (show_array mref) (show_array magic) ;
    (* We skip 4 words = 16 bytes from the beginning, the rest is just marshalled data *)
    Core.In_channel.seek fp 16L ;
    (* We read the full file here instead of passing the channel to pyml because there's a bug:
       In_channel read already too much, and pyml bindings don't account for that. So we'll do the
       reading explicitely and pass in a data buffer instead *)
    let data = Core.In_channel.input_all fp in
    Core.In_channel.close fp ;
    let pyobj = Py.Marshal.read_object_from_string data size in
    from_python_object pyobj


let from_file ~is_binary filename =
  Py.initialize ~interpreter:"/usr/bin/python3.8" () ;
  let code = if is_binary then from_bytecode filename else from_source filename in
  Py.finalize () ;
  code
