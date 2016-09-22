
open Nonstd
module String = Sosa.Native_string

let indel_realigner_config =
  let open Biokepi.Tools.Gatk.Configuration in
  (* We need to ignore reads with no quality scores that BWA includes in the
     BAM, but the GATK's Indel Realigner chokes on (even though the reads are
     unmapped).

     cf. http://gatkforums.broadinstitute.org/discussion/1429/error-bam-file-has-a-read-with-mismatching-number-of-bases-and-base-qualities *)
  let indel_cfg = {
    Indel_realigner.
    name = "ignore-mismatch";
    filter_reads_with_n_cigar = true;
    filter_mismatching_base_and_quals = true;
    filter_bases_not_stored = true;
    parameters = [] }
  in
  let target_cfg = {
    Realigner_target_creator.
    name = "ignore-mismatch";
    filter_reads_with_n_cigar = true;
    filter_mismatching_base_and_quals = true;
    filter_bases_not_stored = true;
    parameters = [] }
  in
  (indel_cfg, target_cfg)

let star_config =
  let open Biokepi.Tools.Star.Configuration.Align in
  {
    name = "mapq_default_60";
    parameters = [];
    (* Cf. https://www.broadinstitute.org/gatk/guide/article?id=3891

    In particular:

       STAR assigns good alignments a MAPQ of 255 (which technically means
       “unknown” and is therefore meaningless to GATK). So we use the GATK’s
       ReassignOneMappingQuality read filter to reassign all good alignments to the
       default value of 60.
    *)
    sam_mapq_unique = Some 60;
    overhang_length = None;
  }


let strelka_config = Biokepi.Tools.Strelka.Configuration.exome_default
let mutect_config = Biokepi.Tools.Mutect.Configuration.default

let mark_dups_config =
  Biokepi.Tools.Picard.Mark_duplicates_settings.default


module Parameters = struct

  type t = {
    (* MHC Alleles which take precedence over those generated by Seq2HLA. *)
    mhc_alleles: string list option;
    with_topiary: bool [@default false];
    with_seq2hla: bool [@default false];
    with_mutect2: bool [@default false];
    with_varscan: bool [@default false];
    with_somaticsniper: bool [@default false];
    bedfile: string option [@default None];
    experiment_name: string [@main];
    reference_build: string;
    normal: Biokepi.EDSL.Library.Input.t;
    tumor: Biokepi.EDSL.Library.Input.t;
    rna: Biokepi.EDSL.Library.Input.t option;
  } [@@deriving show,make]

  let construct_run_name params =
    let {normal;  tumor; rna; experiment_name; reference_build; _} = params in
    let name_of_input i =
      let open Biokepi.EDSL.Library.Input in
      match i with
      | Fastq { sample_name; _ } -> sample_name
    in
    String.concat ~sep:"-" [
      experiment_name;
      name_of_input normal;
      name_of_input tumor;
      Option.value_map ~f:name_of_input rna ~default:"noRNA";
      reference_build;
    ]

  (* To maximize sharing the run-directory depends only on the
     experiement name (to allow the use to force a fresh one) and the
     reference-build (since Biokepi does not track it yet in the filenames). *)
  let construct_run_directory param =
    sprintf "%s-%s" param.experiment_name param.reference_build


  let input_to_string t =
    let open Biokepi.EDSL.Library.Input in
    let fragment =
      function
      | (_, PE (r1, r2)) -> sprintf "Paired-end FASTQ"
      | (_, SE r) -> sprintf "Single-end FASTQ"
      | (_, Of_bam (`SE,_,_, p)) -> "Single-end-from-bam"
      | (_, Of_bam (`PE,_,_, p)) -> "Paired-end-from-bam"
    in
    let same_kind a b =
      match a, b with
      | (_, PE _)              , (_, PE _)               -> true
      | (_, SE _)              , (_, SE _)               -> true
      | (_, Of_bam (`SE,_,_,_)), (_, Of_bam (`SE,_,_,_)) -> true
      | (_, Of_bam (`PE,_,_,_)), (_, Of_bam (`PE,_,_,_)) -> true
      | _, _ -> false
    in
    match t with
    | Fastq { sample_name; files } ->
      sprintf "%s, %s"
        sample_name
        begin match files with
        | [] -> "NONE"
        | [one] ->
          sprintf "1 fragment: %s" (fragment one)
        | one :: more ->
          sprintf "%d fragments: %s"
            (List.length more + 1)
            (if List.for_all more ~f:(fun f -> same_kind f one)
             then "all " ^ (fragment one)
             else "heterogeneous")
        end

  let metadata t = [
    "MHC Alleles",
    begin match t.mhc_alleles  with
    | None  -> "None provided"
    | Some l -> sprintf "Alleles: [%s]" (String.concat l ~sep:"; ")
    end;
    "Reference-build", t.reference_build;
    "Normal-input", input_to_string t.normal;
    "Tumor-input", input_to_string t.tumor;
    "RNA-input", Option.value_map ~default:"N/A" ~f:input_to_string t.rna;
  ]

end


module Full (Bfx: Extended_edsl.Semantics) = struct

  module Stdlib = Biokepi.EDSL.Library.Make(Bfx)

  let to_bam ~reference_build input =
    let list_of_inputs = Stdlib.bwa_mem_opt_inputs input in
    List.map list_of_inputs ~f:(Bfx.bwa_mem_opt ~reference_build ?configuration:None)
    |> Bfx.list
    |> Bfx.merge_bams
    |> Bfx.picard_mark_duplicates
      ~configuration:mark_dups_config

  let final_bams ~normal ~tumor =
    let pair =
      Bfx.pair normal tumor
      |> Bfx.gatk_indel_realigner_joint
        ~configuration:indel_realigner_config
    in
    Bfx.gatk_bqsr (Bfx.pair_first pair), Bfx.gatk_bqsr (Bfx.pair_second pair)


  let vcfs
      ?bedfile
      ~with_mutect2
      ~with_varscan
      ~with_somaticsniper
      ~reference_build ~normal ~tumor =
    let opt_vcf test name somatic vcf =
      if test then [name, somatic, vcf ()] else []
    in
    let vcfs =
      [
        "strelka", true, Bfx.strelka () ~normal ~tumor ~configuration:strelka_config;
        "mutect", true, Bfx.mutect () ~normal ~tumor ~configuration:mutect_config;
        "haplo-normal", false, Bfx.gatk_haplotype_caller normal;
        "haplo-tumor", false, Bfx.gatk_haplotype_caller tumor;
      ]
      @ opt_vcf with_mutect2
        "mutect2" true (fun () -> Bfx.mutect2 ~normal ~tumor ())
      @ opt_vcf with_varscan
        "varscan" true (fun () -> Bfx.varscan_somatic ~normal ~tumor ())
      @ opt_vcf with_somaticsniper
        "somatic-sniper" true (fun () -> Bfx.somaticsniper ~normal ~tumor ())
    in
    match bedfile with
    | None -> vcfs
    | Some bedfile ->
      let bed = (Bfx.bed (Bfx.input_url bedfile)) in
      List.map vcfs ~f:(fun (name, s, v) -> name, s, Bfx.filter_to_region v bed)


  let qc fqs =
    Bfx.concat fqs |> Bfx.fastqc

  let rna_bam ~reference_build fqs =
    Bfx.list_map fqs
      ~f:(Bfx.lambda (fun fq ->
          Bfx.star ~configuration:star_config ~reference_build fq))
    |> Bfx.merge_bams
    |> Bfx.picard_mark_duplicates
      ~configuration:mark_dups_config
    |> Bfx.gatk_indel_realigner
      ~configuration:indel_realigner_config

  let hla fqs =
    Bfx.seq2hla (Bfx.concat fqs) |> Bfx.save "Seq2HLA"

  let rna_pipeline ~reference_build ~with_seq2hla fqs =
    let bam = rna_bam ~reference_build fqs in
    (
      Some (bam |> Bfx.save "rna-bam"),
      Some (bam |> Bfx.stringtie |> Bfx.save "stringtie"),
      (* Seq2HLA does not work on mice: *)
      (match reference_build, with_seq2hla with
      | "mm10", _ -> None
      | _, false -> None
      | _, true -> Some (hla fqs)),
      Some (bam |> Bfx.flagstat |> Bfx.save "rna-bam-flagstat")
    )

  let run parameters =
    let open Parameters in
    let rna = Option.map parameters.rna ~f:Stdlib.fastq_of_input in
    let normal_bam, tumor_bam =
      final_bams
        ~normal:(parameters.normal |> to_bam ~reference_build:parameters.reference_build)
        ~tumor:(parameters.tumor |> to_bam ~reference_build:parameters.reference_build)
      |> (fun (n, t) -> Bfx.save "normal-bam" n, Bfx.save "tumor-bam" t)
    in
    let normal_bam_flagstat, tumor_bam_flagstat =
      Bfx.flagstat normal_bam |> Bfx.save "normal-bam-flagstat",
      Bfx.flagstat tumor_bam |> Bfx.save "tumor-bam-flagstat"
    in
    let bedfile = parameters.bedfile in
    let vcfs =
      let {with_mutect2; with_varscan; with_somaticsniper; _} = parameters in
      vcfs
        ?bedfile
        ~with_mutect2
        ~with_varscan
        ~with_somaticsniper
        ~reference_build:parameters.reference_build
        ~normal:normal_bam ~tumor:tumor_bam in
    let somatic_vcfs =
      List.filter ~f:(fun (_, somatic, _) -> somatic) vcfs
      |> List.map ~f:(fun (_, _, v) -> v) in
    let rna_bam, stringtie, seq2hla, rna_bam_flagstat =
      match rna with
      | None -> None, None, None, None
      | Some r ->
        rna_pipeline r ~reference_build:parameters.reference_build
          ~with_seq2hla:parameters.with_seq2hla
    in
    let maybe_annotated =
      match parameters.reference_build with
      | "b37" | "hg19" ->
        List.map vcfs ~f:(fun (k, somatic, vcf) ->
            Bfx.vcf_annotate_polyphen vcf
            |> fun a -> (k, Bfx.save ("VCF-annotated-" ^ k) a))
      | _ -> List.map vcfs ~f:(fun (name, somatic, v) -> name, (Bfx.save (sprintf "vcf-%s" name) v))
    in
    let mhc_alleles =
      begin match parameters.mhc_alleles, seq2hla with
      | Some alleles, _ -> Some (Bfx.mhc_alleles (`Names alleles))
      | None, Some s ->
        Some (Bfx.hlarp (`Seq2hla s))
      | None, None -> None
      end
    in
    let vaxrank =
      let open Option in
      rna_bam
      >>= fun bam ->
      mhc_alleles
      >>= fun alleles ->
      return (
        Bfx.vaxrank
          somatic_vcfs
          bam
          `NetMHCcons
          alleles
        |> Bfx.save "Vaxrank"
      ) in
    let normal = Stdlib.fastq_of_input parameters.normal in
    let tumor = Stdlib.fastq_of_input parameters.tumor in
    Bfx.observe (fun () ->
        Bfx.report
          (Parameters.construct_run_name parameters)
          ~vcfs:maybe_annotated ?bedfile
          ~qc_normal:(qc normal |> Bfx.save "QC:normal")
          ~qc_tumor:(qc tumor |> Bfx.save "QC:tumor")
          ~normal_bam ~tumor_bam ?rna_bam
          ~normal_bam_flagstat ~tumor_bam_flagstat
          ?vaxrank ?seq2hla ?stringtie ?rna_bam_flagstat
          ~metadata:(Parameters.metadata parameters)
      )
end
