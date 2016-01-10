open Util
open BlockStructure

type cfg_annot = { gen : Intset.t; kill : Intset.t; live_exit : Intset.t }
    [@@deriving show]

type cfg = (int cfg_entry * cfg_annot) list
    [@@deriving show]

(* Add the assigned identifier in a to the generation set *)
let add_gen (a : int atomic_exp) (gen : Intset.t) : Intset.t =
  match a with
  | Bool _ | Num _ -> gen
  | Ident i -> Intset.add i gen

(* Compute the gen and kill sets for a basic block, live_exit is set to empty *)
let analyse_block (b : int basic_block) : cfg_annot =
  let rec analyse_block gen kill b =
    match b with 
    | [] -> (gen, kill)
    | AssignOp (i, a1, op, a2) :: b ->
      analyse_block (add_gen a1 (add_gen a2 (Intset.remove i gen))) 
        (Intset.add i kill) 
        b
    | AssignAtom (i, a) :: b ->
      analyse_block (add_gen a (Intset.remove i gen)) (Intset.add i kill) b
    | Ld (i, addr) :: b -> 
      analyse_block (Intset.remove i gen) (Intset.add i kill) b
    | St (i, addr) :: b ->
      analyse_block (Intset.add i gen) kill b
    | In i :: b ->
      analyse_block (Intset.remove i gen) (Intset.add i kill) b
    | Out i :: b ->
      analyse_block (Intset.add i gen) kill b
  in
  let (gen,kill) = analyse_block Intset.empty Intset.empty (List.rev b) in
  { gen = gen; kill = kill; live_exit = Intset.empty }

(* Split the annotated cfg into the predecessors of node n, and the other nodes *)
let rec find_preds n cfg =
  List.partition 
    (fun (entry, annots) ->
       match entry.next with
       | End -> false
       | Next n' ->
         n = n'
       | Branch (i, n1, n2) ->
         n = n1 || n = n2)
    cfg

(* Do live variable analysis, returning an annotated cfg *)
let lva (cfg : 'reg BlockStructure.cfg) : cfg =
  (* Initial annotations for all of the blocks *)
  let init_worklist = 
    List.map (fun entry -> (entry, analyse_block entry.elems)) cfg 
  in
  (* The worklist and finished_list partition the whole cfg. That is, they must
     contain all of the blocks between them, with no duplication *)
  let rec do_one (worklist :cfg) (finished_list :cfg) : cfg =
    match worklist with
    | [] -> finished_list
    | ((entry, annot) as node) :: worklist ->
      let live_entry = Intset.union annot.gen (Intset.diff annot.live_exit annot.kill) in
      let (updates, worklist) = find_preds entry.index worklist in
      let (possible_updates, finished) = find_preds entry.index (node::finished_list) in
      let (finished', updates') =
        List.partition
          (fun (entry, annot) -> Intset.subset live_entry annot.live_exit)
          possible_updates
      in
      let new_worklist = 
        List.map 
          (fun (entry, annot) ->
             (entry, { annot with live_exit = Intset.union annot.live_exit live_entry}))
          (updates @ updates')
        @ 
        worklist
      in
      do_one new_worklist (finished' @ finished)
  in
  do_one (List.rev init_worklist) []

let rec local_remove_unused_writes (live : Intset.t) (elems : int block_elem list) : int block_elem list =
  match elems with
  | [] -> []
  | AssignOp (i, a1, op, a2) :: b ->
    if Intset.mem i live then
      AssignOp (i, a1, op, a2) ::
      local_remove_unused_writes (add_gen a1 (add_gen a2 (Intset.remove i live))) b
    else
      local_remove_unused_writes live b
  | AssignAtom (i, a) :: b ->
    if Intset.mem i live then
      AssignAtom (i, a) ::
      local_remove_unused_writes (add_gen a (Intset.remove i live)) b
    else
      local_remove_unused_writes live b
  | Ld (i, addr) :: b -> 
    if Intset.mem i live then
      Ld (i, addr) ::
      local_remove_unused_writes (Intset.remove i live) b
    else
      local_remove_unused_writes live b
  | St (i, addr) :: b ->
    St (i, addr) :: local_remove_unused_writes (Intset.add i live) b
  | In i :: b ->
    if Intset.mem i live then
      In i :: local_remove_unused_writes (Intset.remove i live) b
    else
      local_remove_unused_writes live b
  | Out i :: b ->
    Out i :: local_remove_unused_writes (Intset.add i live) b

let remove_unused_writes (cfg : cfg) : cfg =
  List.map 
    (fun (entry, annot) ->
       let new_elems = local_remove_unused_writes annot.live_exit (List.rev entry.elems) in
       ({entry with elems = List.rev new_elems}, annot))
    cfg
