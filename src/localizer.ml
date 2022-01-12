module F = Format
module LineCoverage = Coverage.LineCoverage2

module BugLocation = struct
  type t = Cil.location * float * float * float * int

  let pp fmt (l, score_neg, score_pos, score, score_time) =
    F.fprintf fmt "%s:%d\t%f %f %f %d" l.Cil.file l.Cil.line score_neg score_pos
      score score_time

  let pp_cov fmt (l, score_neg, score_pos, score, _score_time) =
    F.fprintf fmt "%s:%d,%d,%d,%f"
      (l.Cil.file |> Filename.basename)
      l.Cil.line (int_of_float score_pos) (int_of_float score_neg) score

  let pp_file fmt file = F.fprintf fmt "%s" file
end

let print_file bic_locations parent_locations resultname =
  let locations =
    List.fold_left
      (fun acc (l, s1, _, _, _) ->
        if List.mem (l.Cil.file |> Filename.basename) acc || s1 = 0. then acc
        else (l.Cil.file |> Filename.basename) :: acc)
      [] bic_locations
  in
  let locations =
    List.fold_left
      (fun acc (l, s1, _, _, _) ->
        if List.mem (l.Cil.file |> Filename.basename) acc || s1 = 0. then acc
        else (l.Cil.file |> Filename.basename) :: acc)
      locations parent_locations
  in
  let oc3 = Filename.concat !Cmdline.out_dir resultname |> open_out in
  let fmt3 = F.formatter_of_out_channel oc3 in
  List.iter (fun l -> F.fprintf fmt3 "%a\n" BugLocation.pp_file l) locations;
  close_out oc3

let print_coverage locations resultname =
  let oc2 = Filename.concat !Cmdline.out_dir resultname |> open_out in
  let fmt2 = F.formatter_of_out_channel oc2 in
  List.iter (fun l -> F.fprintf fmt2 "%a\n" BugLocation.pp_cov l) locations;
  close_out oc2

let print locations resultname =
  let oc = Filename.concat !Cmdline.out_dir resultname |> open_out in
  let fmt = F.formatter_of_out_channel oc in
  List.iter (fun l -> F.fprintf fmt "%a\n" BugLocation.pp l) locations;
  close_out oc

let copy_src () =
  Unix.create_process "cp"
    [| "cp"; "-rf"; "src"; !Cmdline.out_dir |]
    Unix.stdin Unix.stdout Unix.stderr
  |> ignore;

  match Unix.wait () |> snd with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED n -> failwith ("Error " ^ string_of_int n ^ ": copy failed")
  | _ -> failwith "copy failed"

let dummy_localizer work_dir bug_desc =
  let coverage = LineCoverage.run work_dir bug_desc in
  Logging.log "Coverage: %a" LineCoverage.pp coverage;
  copy_src ();
  List.fold_left
    (fun locs elem ->
      Coverage.StrMap.fold
        (fun file lines locs ->
          let new_locs =
            List.map
              (fun line -> ({ Cil.file; line; byte = 0 }, 0.0, 0.0, 0.0, 0))
              lines
          in
          locs @ new_locs)
        elem.LineCoverage.coverage locs)
    [] coverage

let spec_localizer work_dir bug_desc _ =
  let coverage = LineCoverage.run work_dir bug_desc in
  Logging.log "Coverage: %a" LineCoverage.pp coverage;
  copy_src ();
  let locations =
    List.fold_left
      (fun locs (elem : LineCoverage.elem) ->
        let regexp_pos = Str.regexp "p.*" in
        Coverage.StrMap.fold
          (fun file lines locs ->
            let new_locs =
              if Str.string_match regexp_pos elem.LineCoverage.test 0 then
                List.rev_map
                  (fun line -> ({ Cil.file; line; byte = 0 }, 0.0, 1.0, 0.0, 0))
                  lines
              else
                List.rev_map
                  (fun line ->
                    ( { Cil.file; line; byte = 0 },
                      1.0,
                      0.0,
                      0.0,
                      (*List.find
                          (fun (x, y) -> x = line)
                          elem.LineCoverage.linehistory
                        |> snd *)
                      0 ))
                  lines
            in
            List.rev_append new_locs locs)
          elem.LineCoverage.coverage locs)
      [] coverage
  in
  let table = Hashtbl.create 99999 in
  List.iter
    (fun (l, s1, s2, s3, s4) ->
      match Hashtbl.find_opt table l with
      | Some (new_s1, new_s2, new_s3, new_s4) ->
          Hashtbl.replace table l
            (s1 +. new_s1, s2 +. new_s2, s3 +. new_s3, s4 + new_s4)
      | _ -> Hashtbl.add table l (s1, s2, s3, s4))
    locations;
  let spec =
    List.map
      (fun (l, (s1, s2, s3, s4)) -> (l, s1, s2, s3, s4))
      (List.of_seq (Hashtbl.to_seq table))
  in
  (*"coverage_file.txt"
    |> ( spec
       |> print_file);*)
  spec

let prophet_localizer _work_dir _bug_desc locations =
  List.stable_sort
    (fun (_, s11, s12, _, s14) (_, s21, s22, _, s24) ->
      if s21 -. s11 <> 0. then int_of_float (s21 -. s11)
      else if s12 -. s22 <> 0. then int_of_float (s12 -. s22)
      else s24 - s14)
    locations

let tarantula_localizer _work_dir bug_desc locations =
  let test_cases = bug_desc.BugDesc.test_cases in
  let pos_num =
    List.fold_left
      (fun acc t ->
        let regexp_pos = Str.regexp "p.*" in
        if Str.string_match regexp_pos t 0 then acc + 1 else acc)
      0 test_cases
  in
  let neg_num =
    List.fold_left
      (fun acc t ->
        let regexp_neg = Str.regexp "n.*" in
        if Str.string_match regexp_neg t 0 then acc + 1 else acc)
      0 test_cases
  in
  let taran_loc =
    List.map
      (fun (l, s1, s2, _, _) ->
        let nep = s2 in
        let nnp = float_of_int pos_num -. s2 in
        let nef = s1 in
        let nnf = float_of_int neg_num -. s1 in
        let numer = nef /. (nef +. nnf) in
        let denom1 = nef /. (nef +. nnf) in
        let denom2 = nep /. (nep +. nnp) in
        let score = numer /. (denom1 +. denom2) in
        (l, s1, s2, score, 0))
      locations
  in
  List.stable_sort
    (fun (_, _, _, s13, _) (_, _, _, s23, _) ->
      if s23 > s13 then 1 else if s23 = s13 then 0 else -1)
    taran_loc

let ochiai_localizer _work_dir bug_desc locations =
  let test_cases = bug_desc.BugDesc.test_cases in
  let pos_num =
    List.fold_left
      (fun acc t ->
        let regexp_pos = Str.regexp "p.*" in
        if Str.string_match regexp_pos t 0 then acc + 1 else acc)
      0 test_cases
  in
  let neg_num =
    List.fold_left
      (fun acc t ->
        let regexp_neg = Str.regexp "n.*" in
        if Str.string_match regexp_neg t 0 then acc + 1 else acc)
      0 test_cases
  in
  let ochiai_loc =
    List.map
      (fun (l, s1, s2, _, _) ->
        let nep = s2 in
        let _nnp = float_of_int pos_num -. s2 in
        let nef = s1 in
        let nnf = float_of_int neg_num -. s1 in
        let sub_denom1 = nef +. nnf in
        let sub_denom2 = nef +. nep in
        let denom = sqrt (sub_denom1 *. sub_denom2) in
        let score = nef /. denom in
        (l, s1, s2, score, 0))
      locations
  in
  List.stable_sort
    (fun (_, _, _, s13, _) (_, _, _, s23, _) ->
      if s23 > s13 then 1 else if s23 = s13 then 0 else -1)
    ochiai_loc

let jaccard_localizer _work_dir bug_desc locations =
  let test_cases = bug_desc.BugDesc.test_cases in
  let pos_num =
    List.fold_left
      (fun acc t ->
        let regexp_pos = Str.regexp "p.*" in
        if Str.string_match regexp_pos t 0 then acc + 1 else acc)
      0 test_cases
  in
  let neg_num =
    List.fold_left
      (fun acc t ->
        let regexp_neg = Str.regexp "n.*" in
        if Str.string_match regexp_neg t 0 then acc + 1 else acc)
      0 test_cases
  in
  let jaccard_loc =
    List.map
      (fun (l, s1, s2, _, _) ->
        let nep = s2 in
        let _nnp = float_of_int pos_num -. s2 in
        let nef = s1 in
        let nnf = float_of_int neg_num -. s1 in
        let denom = nef +. nnf +. nep in
        let score = nef /. denom in
        (l, s1, s2, score, 0))
      locations
  in
  List.stable_sort
    (fun (_, _, _, s13, _) (_, _, _, s23, _) ->
      if s23 > s13 then 1 else if s23 = s13 then 0 else -1)
    jaccard_loc

let diff_localizer work_dir bug_desc localizer_list =
  Unix.chdir "/experiment/src";
  Unix.create_process "make" [| "make"; "clean" |] Unix.stdin Unix.stdout
    Unix.stderr
  |> ignore;
  (match Unix.wait () |> snd with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED n ->
      failwith ("Error " ^ string_of_int n ^ ": make clean failed test")
  | _ -> failwith "make clean failed");
  Unix.create_process "make" [| "make"; "distclean" |] Unix.stdin Unix.stdout
    Unix.stderr
  |> ignore;
  (match Unix.wait () |> snd with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED n ->
      failwith ("Error " ^ string_of_int n ^ ": make distclean failed")
  | _ -> failwith "make distclean failed");

  Unix.chdir "/experiment";
  Unix.create_process "cp"
    [| "cp"; "-rf"; "src"; "bic" |]
    Unix.stdin Unix.stdout Unix.stderr
  |> ignore;
  (match Unix.wait () |> snd with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED n -> failwith ("Error " ^ string_of_int n ^ ": cp failed")
  | _ -> failwith "cp failed");

  Unix.chdir "/experiment/src";
  Unix.create_process "./configure" [| "./configure" |] Unix.stdin Unix.stdout
    Unix.stderr
  |> ignore;
  (match Unix.wait () |> snd with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED n ->
      failwith ("Error " ^ string_of_int n ^ ": configure failed")
  | _ -> failwith "configure failed");

  Unix.chdir "/experiment";
  let bic_locations = spec_localizer work_dir bug_desc () in
  (*let bic_result = tarantula_localizer work_dir bug_desc locations in*)
  Unix.chdir "/experiment";
  Unix.create_process "./parent_checkout.sh"
    [| "./parent_checkout.sh" |]
    Unix.stdin Unix.stdout Unix.stderr
  |> ignore;
  (match Unix.wait () |> snd with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED n ->
      failwith ("Error " ^ string_of_int n ^ ": parent script failed test2")
  | _ -> failwith "parent script failed");

  (*let _ = failwith "abc" in*)
  (*Unix.create_process "./line_matching.py"
      [| "./line_matching.py"; "./bic/"; "./src/" |]
      Unix.stdin Unix.stdout Unix.stderr
    |> ignore;
    (match Unix.wait () |> snd with
    | Unix.WEXITED 0 -> ()
    | Unix.WEXITED n -> failwith ("Error " ^ string_of_int n ^ ": diff failed")
    | _ -> failwith "diff failed");*)
  Unix.chdir "/experiment/src";
  Unix.create_process "./configure" [| "./configure" |] Unix.stdin Unix.stdout
    Unix.stderr
  |> ignore;
  (match Unix.wait () |> snd with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED n ->
      failwith ("Error " ^ string_of_int n ^ ": configure failed")
  | _ -> failwith "configure failed");

  Unix.chdir "/experiment";
  let parent_locations = spec_localizer work_dir bug_desc () in

  (*let parent_result = tarantula_localizer work_dir bug_desc locations in*)

  (*Unix.chdir "/experiment/src";
    Unix.create_process "make"
      [| "make"; "clean" |]
      Unix.stdin Unix.stdout Unix.stderr
    |> ignore;
    (match Unix.wait () |> snd with
    | Unix.WEXITED 0 -> ()
    | Unix.WEXITED n -> failwith ("Error " ^ string_of_int n ^ ": make clean failed")
    | _ -> failwith "make clean failed");
    Unix.create_process "make"
      [| "make"; "distclean" |]
      Unix.stdin Unix.stdout Unix.stderr
    |> ignore;
    (match Unix.wait () |> snd with
    | Unix.WEXITED 0 -> ()
    | Unix.WEXITED n -> failwith ("Error " ^ string_of_int n ^ ": make distclean failed")
    | _ -> failwith "make distclean failed");*)
  Unix.chdir "/experiment";
  let open Yojson.Basic.Util in
  let json = Yojson.Basic.from_file "line_matching.json" in
  let changed_file = json |> member "changed_files" |> to_assoc in
  let unchanged_file =
    json |> member "unchanged_files" |> to_list
    |> List.map (fun a -> a |> to_string)
  in
  let table = Hashtbl.create 99999 in
  let table_parent = Hashtbl.create 99999 in
  List.iter
    (fun (l, s1, s2, s3, s4) ->
      match Hashtbl.find_opt table l with
      | Some (new_s1, new_s2, new_s3, new_s4) ->
          Hashtbl.replace table l
            (s1 +. new_s1, s2 +. new_s2, s3 +. new_s3, s4 + new_s4)
      | _ -> Hashtbl.add table l (s1, s2, s3, s4))
    bic_locations;
  let bic_result =
    List.map
      (fun (l, (s1, s2, s3, s4)) -> (l, s1, s2, s3, s4))
      (List.of_seq (Hashtbl.to_seq table))
  in
  List.iter
    (fun (localizer, engine_name) ->
      "coverage_" ^ engine_name ^ "_bic.txt"
      |> (List.map
            (fun (l, (s1, s2, s3, s4)) -> (l, s1, s2, s3, s4))
            (List.of_seq (Hashtbl.to_seq table))
         |> localizer work_dir bug_desc
         |> print_coverage)
      (*print_file bic_result "coverage_file.txt"*))
    localizer_list;
  List.iter
    (fun (l, s1, s2, s3, s4) ->
      match Hashtbl.find_opt table_parent l with
      | Some (new_s1, new_s2, new_s3, new_s4) ->
          Hashtbl.replace table_parent l
            (s1 +. new_s1, s2 +. new_s2, s3 +. new_s3, s4 + new_s4)
      | _ -> Hashtbl.add table_parent l (s1, s2, s3, s4))
    parent_locations;
  let parent_result =
    List.map
      (fun (l, (s1, s2, s3, s4)) -> (l, s1, s2, s3, s4))
      (List.of_seq (Hashtbl.to_seq table_parent))
  in
  print_coverage parent_result "coverage_parent.txt";
  print_file bic_result parent_result "coverage_file.txt";
  List.iter
    (fun (l, s1, s2, s3, s4) ->
      let new_l =
        if List.mem l.Cil.file unchanged_file then Some l
        else
          match List.assoc_opt l.Cil.file changed_file with
          | Some v
            when l.Cil.line - 1 < List.length (v |> to_list)
                 && List.nth (v |> to_list) (l.Cil.line - 1) |> to_int <> 0 ->
              Some
                {
                  Cil.file = l.Cil.file;
                  line = List.nth (v |> to_list) (l.Cil.line - 1) |> to_int;
                  byte = 0;
                }
          | _ -> None
      in
      if new_l <> None then
        let l = Option.get new_l in
        match Hashtbl.find_opt table l with
        | Some (new_s1, new_s2, new_s3, new_s4) ->
            Hashtbl.replace table l
              (new_s1, s1 +. s2 +. new_s2, s3 +. new_s3, s4 + new_s4)
        | _ -> Hashtbl.add table l (0., s1 +. s2, s3, s4))
    parent_locations;
  let result =
    List.map
      (fun (l, (s1, s2, s3, s4)) -> (l, s1, s2, s3, s4))
      (List.of_seq (Hashtbl.to_seq table))
  in
  print_coverage result "coverage_diff.txt";
  result

let unival_compile scenario bug_desc =
  Unix.chdir scenario.Scenario.work_dir;
  if not !Cmdline.skip_compile then Logging.log "Start compile";
  Scenario.compile scenario bug_desc.BugDesc.compiler_type;
  Unix.chdir scenario.Scenario.work_dir

let unival_run_test scenario bug_desc =
  Logging.log "Start test";
  let text_file_name =
    Filename.concat scenario.Scenario.work_dir "output.txt"
  in
  List.iter
    (fun test ->
      let oc = open_out_gen [ Open_append; Open_creat ] 0o775 text_file_name in
      Printf.fprintf oc "*** new execution ***,%s,%d\n" test
        (if String.get test 0 = 'p' then 0 else 1);
      close_out oc;
      Unix.create_process scenario.Scenario.test_script
        [| scenario.Scenario.test_script; test |]
        Unix.stdin Unix.stdout
        (* (Unix.openfile
           (Filename.concat work_dir "output.txt")
           [ Unix.O_CREAT; Unix.O_WRONLY; Unix.O_CREAT ]
           0o775) *)
        Unix.stderr
      |> ignore;
      Unix.wait () |> ignore;
      Logging.log "End test %s" test)
    bug_desc.BugDesc.test_cases

let unival_localizer work_dir bug_desc =
  let scenario = Scenario.init work_dir in
  unival_compile scenario bug_desc;
  Instrument.run scenario.work_dir;
  unival_compile scenario bug_desc;
  unival_run_test scenario bug_desc;
  List.iter
    (fun filename ->
      Unix.create_process "cp"
        [|
          "cp";
          "-rf";
          Filename.concat scenario.work_dir filename;
          Filename.concat scenario.work_dir "localizer-out/";
        |]
        Unix.stdin Unix.stdout Unix.stderr
      |> ignore;
      Unix.wait () |> ignore)
    [ "output.txt"; "CausalMap.txt"; "FaultCandidates.txt"; "src/" ]

let coverage work_dir bug_desc =
  let scenario = Scenario.init ~stdio_only:true work_dir in
  Unix.chdir scenario.Scenario.work_dir;
  Scenario.compile scenario bug_desc.BugDesc.compiler_type;
  Instrument.run scenario.work_dir;
  Unix.chdir scenario.Scenario.work_dir;
  Scenario.compile scenario bug_desc.BugDesc.compiler_type

let run work_dir =
  Logging.log "Start localization";
  let bug_desc = BugDesc.read work_dir in
  Logging.log "Bug desc: %a" BugDesc.pp bug_desc;
  let localizer = if !Cmdline.bic then diff_localizer else spec_localizer in
  match !Cmdline.engine with
  | Cmdline.Dummy ->
      "result_dummy.txt" |> (dummy_localizer work_dir bug_desc |> print)
  | Cmdline.Tarantula ->
      let locations =
        localizer work_dir bug_desc [ (tarantula_localizer, "tarantula") ]
      in
      "result_tarantula.txt"
      |> (tarantula_localizer work_dir bug_desc locations |> print)
  | Cmdline.Prophet ->
      let locations =
        localizer work_dir bug_desc [ (prophet_localizer, "prophet") ]
      in
      "result_prophet.txt"
      |> (prophet_localizer work_dir bug_desc locations |> print)
  | Cmdline.Jaccard ->
      let locations =
        localizer work_dir bug_desc [ (jaccard_localizer, "jaccard") ]
      in
      "result_jaccard.txt"
      |> (jaccard_localizer work_dir bug_desc locations |> print)
  | Cmdline.Ochiai ->
      let locations =
        localizer work_dir bug_desc [ (ochiai_localizer, "ochiai") ]
      in
      "result_ochiai.txt"
      |> (ochiai_localizer work_dir bug_desc locations |> print)
  | Cmdline.UniVal -> unival_localizer work_dir bug_desc
  | Cmdline.All ->
      (*"result_unival.txt" |> (unival_localizer work_dir bug_desc |> print);*)
      let locations =
        localizer work_dir bug_desc
          [
            (prophet_localizer, "prophet");
            (tarantula_localizer, "tarantula");
            (jaccard_localizer, "jaccard");
            (ochiai_localizer, "ochiai");
          ]
      in
      "result_prophet.txt"
      |> (prophet_localizer work_dir bug_desc locations |> print);
      "result_tarantula.txt"
      |> (tarantula_localizer work_dir bug_desc locations |> print);
      "result_jaccard.txt"
      |> (jaccard_localizer work_dir bug_desc locations |> print);
      "result_ochiai.txt"
      |> (ochiai_localizer work_dir bug_desc locations |> print)
  | Cmdline.Coverage -> coverage work_dir bug_desc
