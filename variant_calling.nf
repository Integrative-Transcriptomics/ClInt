process REFERENCE_HELP_FILES {
    // This process mainly relates to the necessary side-files
    // such as the .fai and .dict files for the reference genome
    // as these are required in some of the processes

    input:
        path ref_file

    output:
        path "${ref_file}.fai" emit: fai
        path "${ref_file.baseName}.dict" emit: dict
        // stdout emit: verbo


    script:
    """
    echo "Running samtools faidx and docker"
    samtools faidx ${ref_file}
    gatk CreateSequenceDictionary -R \$PWD/${ref_file} -O \$PWD/${ref_file.baseName}.dict
    ls -lah
    """

    stub:
    """
    touch ${ref_file}.fai
    touch ${ref_file.baseName}.dict
    """
}

process MarkDuplicates {
    // NOTE: We an add --REMOVE_DUPLICATES=true to remove duplicates from the final BAM file
    //       intead of just switching the flag for that read
    label 'variant_calling'
    publishDir "${params.output_dir}/deduped_bam/", mode: 'copy', overwrite: true
    input:
        tuple val(sample_id), path(aligned_bam), path(bai)

    output:
        tuple val(sample_id), path("dedup_*"), path(bai)

    script:
    // TODO: Add "--remove-duplicates" options maybe? To actually remove the duplicates
    """
    echo "Working on ${aligned_bam}"
    gatk MarkDuplicates -I \$PWD/${aligned_bam} -O \$PWD/dedup_${aligned_bam} -M \$PWD/dedup_${aligned_bam}.metrics
    """

    stub:
    """
    touch dedup_${aligned_bam}
    """
}

process SplitNCigarReads {
    label 'variant_calling'
    input:
        tuple val(sample_id), path(bam), path(bai)
        path ref_fai
        path ref_dict
        path ref

    output:
        tuple val(sample_id), path("snc_*"), path(bai)
        // stdout emit: temp
    

    // TODO: Parallelise using interval list, in pairs of 2
    // TODO :This is currently done as a single process/job submission, maybe split it into multiple jobs? Then collect and converge
    // FIXME: This might just be overwriting at each interval, so do the looping somewhere else
    script:
    def chromosomes = (1..22) + ['X', 'Y']

    """
    chromosomes=({1..22} X Y)
    for i in "\${chromosomes[@]}"; do
        echo "Working on ${bam}"
        gatk SplitNCigarReads -R \$PWD/${ref} -I \$PWD/${bam} -O \$PWD/snc_${bam} -L \${i}
    #done
    #echo "Working on ${bam}"
    #gatk SplitNCigarReads -R \$PWD/${ref} -I \$PWD/${bam} -O \$PWD/snc_${bam}
    """

    stub:
    """
    touch snc_${bam_bai}
    """
}

process HaplotypeCaller {
    label 'variant_calling'
    publishDir "${params.output_dir}/haplotype_vcf/rna_spades", mode: 'copy', overwrite: true, pattern: "*spades_*.vcf"
    publishDir "${params.output_dir}/haplotype_vcf/Trinity-GG", mode: 'copy', overwrite: true, pattern: "*Trinity-GG_*.vcf"
    // FIXME: Maybe fix this so that non-assembled ones have their own name? But currently based upon that
    //        only the non-assembled ones don't have a method between "snc" and "trimmed"
    publishDir "${params.output_dir}/haplotype_vcf/normal", mode: 'copy', overwrite: true, pattern: "*snc_trimmed*.vcf"
    input:
        tuple val(sample_id), path("snc_*"), path(bai)
        path ref_fai
        path ref_dict
        path ref

    output:
        path "haplotype_*.vcf"


    // TODO: Change to Mutec2 since HaplotypeCaller is Germline, and we are doing somatic
    // TODO: Split by chromosome. Either have a for loop in the command block (each of them uses chromosome interval)
    // or then do it on the process-level
    // TODO: Implement bcftools concat to merge them back together
    // TODO: Remove samtools index from here, and instead propogate the ".bai" file throughout the proceeses
    //      This would require modifying input for the previous steps
    script:
    """
    echo "Working on ${split_bam}"
    samtools index ${split_bam}

    chromosomes=({1..22} X Y)
    for i in "\${chromosomes[@]}"; do
        echo "Working on ${split_bam}"
        gatk --java-options '-Xmx4G -XX:+UseParallelGC -XX:ParallelGCThreads=4' HaplotypeCaller \
            --pair-hmm-implementation FASTEST_AVAILABLE \
            --native-pair-hmm-threads ${task.cpus} \
            --smith-waterman FASTEST_AVAILABLE \
            -R \$PWD/${ref} -I \$PWD/${split_bam} -O \$PWD/haplotype_${split_bam}.vcf
    done
    #touch haplotype_${split_bam.simpleName}.vcf
    ls -lah
    """

    stub:
    """
    touch haplotype_${split_bam.simpleName}.vcf
    """
}

process VariantFiltering {
    label 'variant_calling'
    publishDir "${params.output_dir}/filtered_vcf/rna_spades", mode: 'copy', overwrite: true, pattern: "*spades_*.vcf"
    publishDir "${params.output_dir}/filtered_vcf/Trinity-GG", mode: 'copy', overwrite: true, pattern: "*Trinity-GG_*.vcf"
    publishDir "${params.output_dir}/filtered_vcf/normal", mode: 'copy', overwrite: true, pattern: "*snc_trimmed*.vcf"

    input:
        path vcf
        path ref
        path ref_fai
        path ref_dict

    output:
        path "*.vcf"

    script:
    // Layout: [Filter Expression, Filtername]
    def filter_options = [
        ["FS > 20", "FS20"]
        ["QUAL > 20", "FS20"]
        ]
    def filtering_args = ""
    filter_options.each { expr, name ->
        filtering_args += "--genotype-filter-expression \"${expr}\" --genotype-filter-name \"${name}\" "
    }
    // println ${filtering_args}
    // TODO: Integrate the filtering args into the command block
    """
    gatk --java-options '-Xmx4G -XX:+UseParallelGC -XX:ParallelGCThreads=4' \
        -R \$PWD/${ref} \
        -I \$PWD/${vcf} \
        -O \$PWD/${vcf.simpleName}_filtered.vcf \
        ${filtering_args}
    """
}


workflow VARIANT_CALLING {
    take:
        sorted_index_bam // Sample ID + BAM/BAI
        ref
    main:
        // TODO: Combine ref_fai, ref_dict and ref into one thing
        REFERENCE_HELP_FILES(ref)
        (ref_fai, ref_dict) = REFERENCE_HELP_FILES.out

        // TODO: For each sample id, split bam up to process, and then merge them back together
        bam_split_n = SplitNCigarReads(sorted_index_bam, ref_fai, ref_dict, ref)
        // | MarkDuplicates
        // haplotype_vcf = HaplotypeCaller(bam_split_n, ref_fai, ref_dict, ref)
    emit:
        // split_bam
        haplotype_vcf
}

// TODO: Avoid sending tuple from sorted_index_bam to all the others (since some of them require )
// use named outputs?
