#!/usr/bin/env nextflow
nextflow.enable.dsl=2

include { PREPROCESS } from './preprocess'
include { MAPPING } from './mapping'
include { CIRCRNA } from './circrna'
include { ASSEMBLY } from './assembly'
include { VARIANT_CALLING } from './variant_calling'

workflow {
    // Do a quick parameter check
    CHECKPARAMS()

    // If paired-end but no samplesheet is given, use the directories
    if (params.paired && !params.samplesheet) {
        input_reads = Channel.fromFilePairs("${params.input_dir}/*{${params.r1_pattern},${params.r2_pattern}}*.f*q.[gz|bz2]?",
                                            type: 'file',
                                            maxDepth: 5)
    } else {
        input_reads = Channel.fromPath("${params.input_dir}/*.f*q.[gz|bz2]?", type: 'file', maxDepth: 5)
                    .map(read -> tuple(read.simpleName, read))
    }

    // If we are given a sample sheet, use that instead
    if (params.samplesheet) {
        input_reads = Channel.fromPath("${params.samplesheet}") | \
                    splitCsv(header:true) | \
                    map { row -> tuple(row.sample, [file(row.fastq_1), file(row.fastq_2)]) }
    }

    reference = Channel.fromPath(params.reference_file).first();
    annotation = Channel.fromPath(params.gff_file).first();
    

    input_reads.view()
    println input_reads
    PREPROCESS(input_reads)
    CIRCRNA(PREPROCESS.out, reference, annotation)
    
    // MAPPING(PREPROCESS.out, reference, annotation)
    // VARIANT_CALLING(MAPPING.out, reference) // Places files in output folder


}


def CHECKPARAMS() {
    println "Checking parameters..."
    if (params.input_dir == '') {
        error "ERROR: input_reads_path is not set"
    } else if (params.output_dir == '') {
        error "ERROR: output_dir is not set"
    } else if (params.reference_file == '') {
        error "ERROR: reference_file is not set"
    } else if (params.gff_file == '') {
        error "ERROR: gff_file is not set"
    } else {
        println "All necessary parameters are set"
        println "  Input Directory  : $params.input_dir"
        println "  Output Directory : $params.output_dir"
        println "  Reference Dir    :  $params.reference_dir"
        println "  Reference file   : $params.reference_file"
        println "  GFF file         :  $params.gff_file"
        println "  Number of cores  :  $params.max_memory"
        println "  Max memory       :  $params.max_memory"
        println "  Genome Index     :  $params.star_index"
        println "  Known SNPs       :  $params.known_sites"
        println "  Paired?          :  $params.paired"
        println "  Star Two-pass?   :  $params.star_two_pass"
        println "  Strandedness     :  $params.strandedness"
        println "  R1 Pattern       : $params.r1_pattern"
        println "  R2 Pattern       : $params.r2_pattern"
    }
}
