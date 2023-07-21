#!/usr/bin/env nextflow

include { MAPPING } from './reuse'
include { MAPPING as REMAPPING} from './reuse'

nextflow.enable.dsl=2

// Set up some params
params.input_reads = file("${params.input_reads_path}/*.f*q.gz");
params.output_dir = file("./workflow_output"); // Default to subdir in current dir
REFERENCE = file(params.reference_file); // Require as file() can't be empty
ANNOTATION = file(params.gff_file); // Require as file() can't be empty

// FIXME: GATK interacts weirdly with .fna files, as in it looks for
//        fname.dict instead of fname.fna.dict, but it works with .fasta; but for ".fai" it looks for fname.fna.fai
//        https://gatk.broadinstitute.org/hc/en-us/community/posts/9688967985691-Does-GATK4-BaseRecalibrator-not-understand-relative-paths-
//        Possible workaround:
//        1. Rename genome files to have .fasta extension when creating/reading (since this initial symlink is propogated)
//        2. Check for the extensions during the Help_file creation, and then adjust the file names accordingly ({ref.baseName}.dict or {ref}.dict)
//        3. TO CHECK: Maybe this happens with fasta as well --> look into it
//        4. Use samtools dict to create the dict file
// FIXME: Simplify ref_fai, ref_dict, and ref_genome to just be ref_files?
// FIXME: Tinity-GG output file should have some sort of identifier in the name,
//        since it will be the same for all samples. Use sample name. This causes problems in VCF creation / publishDir
// TODO: Enable setting read direction in nextflow.config (e.g F / R for unpaired or RF / FR for paired in Trinity)
//       Each program (hisat, trinity) has their own settings depending on the input so this is a bit tricky

def docker_current_dir() {
    // Simple function to return the docker command for the current process (as the PWD is different for each process)

    // This is a bit of a hack, since the docker container would need to get the reference file from the host,
    // but inputs into processes are symlinked to their original location, so the docker container can't see them

    // That is the reason why we are mounting REF_FULLPATH into the container, so that it can see the reference file
    // from the symlink that is given as input
    REF_FULLPATH = "realpath ${params.reference_file}".execute().text.trim()
    // "docker run -v \$PWD:\$PWD -v ${REF_FULLPATH}:${REF_FULLPATH} --user ${params.USER_ID}:${params.GROUP_ID}"
    "docker run -v $PWD:$PWD -v \$PWD:\$PWD -v ${REF_FULLPATH}:${REF_FULLPATH} --user ${params.USER_ID}:${params.GROUP_ID}"
}

def CHECKPARAMS() {
    // Simple function to check if all parameters are set

    println "Checking parameters..."
    if (params.input_reads_path == '') {
        error "ERROR: input_reads_path is not set"
    } else if (params.output_dir == '') {
        error "ERROR: output_dir is not set"
    } else if (params.reference_file == '') {
        error "ERROR: reference_file is not set"
    } else if (params.gff_file == '') {
        error "ERROR: gff_file is not set"
    } else {
        println "All parameters are set"
        println "   |-User ID:\t ${params.USER_ID}"
        println "   |-Group ID:\t ${params.GROUP_ID}"
        println "   |-Input reads:\t ${params.input_reads_path}"
        println "   |-Output dir:\t ${params.output_dir}"
        println "   |-Reference:\t ${params.reference_file}"
        println "   |-GFF file:\t ${params.gff_file}"
    }
}

// --------------------Program-specific Processes-------------------------
process QUALITYCONTROL {
    maxForks 5
    // if ($PUBLISH_DIRECTORIES == 1) {
    //     publishDir "${params.output_dir}/QC" // mode: 'copy',
    // }
    
    input:
        path read

    output:
        path "trimmed_*"
        // stdout emit: verb


    script:
    """
    echo "Working on ${read}"
    fastp -i ${read} -o trimmed_${read} -j /dev/null -h /dev/null
    """
}

process REFERENCE_HELP_FILES {
    // This process mainly relates to the necessary side-files
    // such as the .fai and .dict files for the reference genome
    // as these are required in some of the processes

    input: 
        path ref_file

    output:
        path "${ref_file}.fai" 
        path "${ref_file.baseName}.dict" 
        // stdout emit: verbo


    def docker = docker_current_dir()
    script:
    """
    echo "Running samtools faidx and docker"
    samtools faidx ${ref_file}
    ${docker} broadinstitute/gatk gatk CreateSequenceDictionary -R \$PWD/${ref_file} -O \$PWD/${ref_file.baseName}.dict
    #${docker} broadinstitute/gatk gatk CreateSequenceDictionary -R \$PWD/${ref_file} -O \$PWD/${ref_file}.dict
    ls -lah
    """
}


process SAMTOOLS_SORT {
    maxForks 5
    input:
        path sam_file

    output:
        path "*.bam"

    script:
    def NUM_THREADS = 4
    """
    echo "Sorting ${sam_file}"
    samtools sort -@ $NUM_THREADS -o ${sam_file.simpleName}.bam ${sam_file}
    """
}

process HISAT_BUILD {
    maxForks 5
    input:
        path ref_file
    output:
        path "ref_idx*.ht2"

    script:
    def NUM_THREADS = 4
    def index_name = "ref_idx"
    """
    echo "Running hisat2-build"
    hisat2-build -p $NUM_THREADS  ${ref_file} ${index_name}
    # touch ref_idx.1.ht2
    # touch ref_idx.2.ht2
    # touch ref_idx.3.ht2
    # ls -lah
    """
}

process HISAT2 {
    maxForks 5
    input:
        path ref_idx
        path reads


    output:
        path "*.sam"

    script:
    def aligned_fname = "${reads.simpleName}"
    def NUM_THREADS = 4
    def index_name = "ref_idx"
    def extension = "${reads.extension}"

    println "[LOG] HISAT2 :: Extension is ${extension}"
    if (extension == 'fasta') {
        """
        echo "Fasta file detected"
        hisat2 -f -p $NUM_THREADS --rg-id ${reads} --rg SM:None --rg LB:None --rg PL:Illumina -x ${index_name} -U ${reads} -S ${aligned_fname}.sam
        """
    } else {
        """
        echo "Fastq file detected"
        hisat2 -p $NUM_THREADS --rg-id ${reads} --rg SM:None --rg LB:None --rg PL:Illumina -x ${index_name} -U ${reads} -S ${aligned_fname}.sam
        """
    }

    // """
    // echo "Using hisat2 to align reads ${reads}"
    // hisat2 -p $NUM_THREADS --rg-id ${reads} --rg SM:None --rg LB:None --rg PL:Illumina -x ${index_name} -U ${reads} -S ${aligned_fname}.sam
    // # samtools sort -@ $NUM_THREADS -o ${aligned_fname}.bam ${aligned_fname}.sam
    // # touch aligned_${reads}.bam
    // # ls -lah
    // """
}

process STAR_BUILD {
    maxForks 5
    input:
        path ref_file
        path annotation
    output:
        path "*"

    script:
    def NUM_THREADS = 4
    def READ_LENGTH = 100
    def feature = "gene"
    def extension = annotation.extension
    if (extension == 'gtf') {
        """
            echo "GTF file detected"
            echo "STAR --runThreadN $NUM_THREADS \
            --runMode genomeGenerate \
            --genomeDir . \
            --genomeFastaFiles $ref_file \
            --sjdbGTFfile $annotation \
            --sjdbOverhang \$(($READ_LENGTH - 1))"
            touch one.txt
        """
    } else {
        """
            echo "GFF file detected"
            echo "STAR --runThreadN $NUM_THREADS \
            --runMode genomeGenerate \
            --genomeDir . \
            --genomeFastaFiles $ref_file \
            --sjdbGTFfile $annotation \
            --sjdbGTFtagExonParentTranscript Parent \
            --sjdbGTFfeatureExon $feature \
            --sjdbOverhang \$(($READ_LENGTH - 1))"
            touch one.txt
        """
    }
}

process STAR {
    maxForks 5
    input:
        path ref_idx
        path reads

    output:
        path "aligned_*.bam"

    script:
    def NUM_THREADS = 4
    def SAM_HEADER = "@RG\tID:aligned_${reads}\tSM:None\tLB:None\tPL:Illumina"
    """
    echo "Working on ${reads}"
    echo "STAR --runThreadN $NUM_THREADS \
    --genomeDir ${ref_idx} \
    --readFilesIn ${reads} \
    --readFilesCommand zcat \
    --outSAMtype BAM SortedByCoordinate \
    --outFileNamePrefix aligned_ \
    --outSAMattrRGline $SAM_HEADER \
    --limitBAMsortRAM 10000000000"
    touch aligned_${reads.simpleName}.bam
    """
}


process TRINITY_DENOVO {
    maxForks 6
    input:
        path reads
    output:
        path "Trinity*.fasta"

    script:
    def NUM_THREADS = 4
    """
    echo "Working on ${reads}"
    $docker trinityrnaseq/trinityrnaseq Trinity \
    --seqType fq \
    --max_memory 10G \
    --single ${reads} \
    --CPU $NUM_THREADS \
    --output \$PWD/trinity/

    #--left ${reads} --right ${reads} # If paired-ends
    mv trinity/Trinity.fasta TrinityDeNovo_${sorted_aligned_bam}.fasta
    """
}

process TRINITY_GUIDED {
    maxForks 6
    input:
        path sorted_aligned_bam

    output:
        path "*Trinity-GG*.fasta"
        // path "Trinity-GG_${sorted_aligned_bam}.fasta"


    def docker = docker_current_dir()

    script:
    def NUM_THREADS = 4
    def max_intron = 10000
    """ 
    ls -lah
    $docker trinityrnaseq/trinityrnaseq Trinity \
    --genome_guided_bam \$PWD/$sorted_aligned_bam \
    --genome_guided_max_intron ${max_intron} \
    --max_memory 40G \
    --CPU $NUM_THREADS \
    --output \$PWD/trinity/

    mv trinity/Trinity-GG.fasta Trinity-GG_${sorted_aligned_bam}.fasta
    """
        
}

process RNASpades {
    maxForks 5
    input:
        path reads

    output:
        path "rnaspades_${reads.baseName}.fasta"

    """
    spades.py --rna -ss-fr ${reads} -o spades_out
    mv spades_out/transcripts.fasta rnaspades_${reads.baseName}.fasta
    """
}

process MarkDuplicates {
    // NOTE: We an add --REMOVE_DUPLICATES=true to remove duplicates from the final BAM file
    //       intead of just switching the flag for that read
    maxForks 5
    input:
        path aligned_bam

    output:
        path "dedup_${aligned_bam}"

    def docker = docker_current_dir()

    script:
    """
    echo "Working on ${aligned_bam}"
    ${docker} broadinstitute/gatk gatk MarkDuplicates -I \$PWD/${aligned_bam} -O \$PWD/dedup_${aligned_bam} -M \$PWD/dedup_${aligned_bam}.metrics
    """
}

process SplitNCigarReads {
    // TODO: Change aligned_bam to dedup_bam, and change the output to dedup_${aligned_bam}, because we wanna remove duplicates first
    maxForks 8
    input:
        path aligned_bam
        path ref_fai
        path ref_dict
        path ref

    output:
        path "snc_${aligned_bam}"
        // stdout emit: temp
    
    def docker = docker_current_dir()

    script:
    def NUM_THREADS = 4
    """
    echo "Working on ${aligned_bam}"

    ${docker} broadinstitute/gatk gatk SplitNCigarReads -R \$PWD/${ref} -I \$PWD/${aligned_bam} -O \$PWD/snc_${aligned_bam}

    # ${docker} broadinstitute/gatk bash -c "cd \$PWD/; ls -lah ../../"
    # ${docker} broadinstitute/gatk gatk SplitNCigarReads -R \$PWD/${ref} -I \$PWD/${aligned_bam} -O \$PWD/snc_${aligned_bam}
    # echo "gatk SplitNCigarReads -R ${ref} -I ${aligned_bam} -O split_${aligned_bam}"
    # touch snc_${aligned_bam}
    # ls -lah
    """
}

process HaplotypeCaller {
    maxForks 8
    publishDir "${params.output_dir}/haplotype_vcf/", mode: 'copy', overwrite: true
    input:
        path split_bam
        path ref_fai
        path ref_dict
        path ref

    output:
        path "haplotype_*.vcf"

    def docker = docker_current_dir()

    script:
    def NUM_THREADS = 4
    """
    echo "Working on ${split_bam}"
    samtools index ${split_bam}
    $docker broadinstitute/gatk gatk --java-options '-Xmx4G -XX:+UseParallelGC -XX:ParallelGCThreads=4' HaplotypeCaller \
    --pair-hmm-implementation FASTEST_AVAILABLE \
    --smith-waterman FASTEST_AVAILABLE \
    -R \$PWD/${ref} -I \$PWD/${split_bam} -O \$PWD/haplotype_${split_bam}.vcf
    #touch haplotype_${split_bam.simpleName}.vcf
    ls -lah
    """
}

// -----------------------------------------------------------------------

workflow ASSEMBLY {
    take:
        reads
        bam_files
        method
    main:
        // Check each element of the assembly array, and run the appropriate assembly processes
        // (e.g. Trinity, RNASpades, etc.)

        // NOTE: For some reason placing Mapping outside oeach of those things, 

        // TODO: Do we need to do BAM sorting here? Or can we just use BAM files straight?
        transcripts_fasta = ""
        if ("$method" == "trinity") {
            trinity_mode = params.trinity_type.toLowerCase()
            if ("$trinity_mode" == "denovo") {
                transcripts_fasta = TRINITY_DENOVO(reads) 
            } else if ("$trinity_mode" == "guided") {
                transcripts_fasta = TRINITY_GUIDED(bam_files) 
            } else {
                println "ERROR: Unknown trinity_mode"
            }
            MAPPING(REFERENCE, transcripts_fasta) // Will output bams
            // Realign transcripts (fasta) to reference again
            bams = MAPPING.out
        } else if ("$method" == "rnaspades") {
            // transcripts_fasta = RNASpades(reads)
            // RNASpades.out.view()
            // Realign transcripts (fasta) to reference again
        } else {
            println "ERROR: Assembly method \"${method}\" not recognised"
        }
    emit:
        bams
}

workflow GATK {
    // Run SplitNCigarReads and HaplotypeCaller
    take:
        bam
        ref_fai
        ref_dict
        ref
    main:
        split_bam = SplitNCigarReads(bam, ref_fai, ref_dict, ref) | MarkDuplicates
        haplotype_vcf = HaplotypeCaller(split_bam, ref_fai, ref_dict, ref)
    emit:
        haplotype_vcf
}


workflow {
    CHECKPARAMS()
    READS = QUALITYCONTROL(Channel.fromPath(params.input_reads))
    
    REFERENCE_HELP_FILES(REFERENCE)
    (ref_fai, ref_dict) = REFERENCE_HELP_FILES.out

    MAPPING(REFERENCE, READS) // Will output bams

    // params.assembly.each { method ->
    //     method = method.toLowerCase()
    //     ASSEMBLY(READS, MAPPING.out, method) // Will output fasta
    // }
    // ASSEMBLY(READS, MAPPING.out) // Will output fasta

    // GATK(MAPPING.out.concat(ASSEMBLY.out), ref_fai, ref_dict, REFERENCE)
    // GATK.out.view()
}

/*
    * Notes on nextflow:
        * If you wanna see stdout, its "PROCESS.out.view()"
        * If you want to define a variable within a process, use "def" after the input/output section
        * the 'val' keyword can be used an ulimited number of times, in comparison to channles which can only be used once 
            (and are consumed)
            Actually, it seems that DSL2 allows for re-use of channels
        * For passing i.e ".ht2" files all at once, we can do a collect() on the output of the process which produces these index files

*/