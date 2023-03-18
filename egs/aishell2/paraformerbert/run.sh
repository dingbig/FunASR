#!/usr/bin/env bash

. ./path.sh || exit 1;

# machines configuration
CUDA_VISIBLE_DEVICES="0,1,2,3,4,5,6,7"
gpu_num=8
count=1
gpu_inference=true  # Whether to perform gpu decoding, set false for cpu decoding
# for gpu decoding, inference_nj=ngpu*njob; for cpu decoding, inference_nj=njob
njob=5
train_cmd=tools/run.pl
infer_cmd=utils/run.pl

# general configuration
feats_dir="../DATA" #feature output dictionary, for large data
exp_dir="."
lang=zh
dumpdir=dump/fbank
feats_type=fbank
token_type=char
dataset_type=large
scp=feats.scp
type=kaldi_ark
stage=0
stop_stage=5

skip_extract_embed=false
bert_model_root="../../huggingface_models"
bert_model_name="bert-base-chinese"

# feature configuration
feats_dim=80
sample_frequency=16000
nj=100
speed_perturb="0.9,1.0,1.1"

# data
tr_dir=
dev_tst_dir=

# exp tag
tag="exp1"

. utils/parse_options.sh || exit 1;

# Set bash to 'debug' mode, it will exit on :
# -e 'error', -u 'undefined variable', -o ... 'error in pipeline', -x 'print commands',
set -e
set -u
set -o pipefail

train_set=train
valid_set=dev_ios
test_sets="dev_ios test_ios"

asr_config=conf/train_asr_paraformerbert_conformer_20e_6d_1280_320.yaml
model_dir="baseline_$(basename "${asr_config}" .yaml)_${feats_type}_${lang}_${token_type}_${tag}"

inference_config=conf/decode_asr_transformer_noctc_1best.yaml
inference_asr_model=valid.acc.ave_10best.pb

# you can set gpu num for decoding here
gpuid_list=$CUDA_VISIBLE_DEVICES  # set gpus for decoding, e.g., gpuid_list=2,3, the same as training stage by default
ngpu=$(echo $gpuid_list | awk -F "," '{print NF}')

if ${gpu_inference}; then
    inference_nj=$[${ngpu}*${njob}]
    _ngpu=1
else
    inference_nj=$njob
    _ngpu=0
fi

if [ ${stage} -le 0 ] && [ ${stop_stage} -ge 0 ]; then
    echo "stage 0: Data preparation"
    # For training set
    local/prepare_data.sh ${tr_dir} data/local/train data/train || exit 1;
    # # For dev and test set
    for x in Android iOS Mic; do
        local/prepare_data.sh ${dev_tst_dir}/${x}/dev data/local/dev_${x,,} data/dev_${x,,} || exit 1;
        local/prepare_data.sh ${dev_tst_dir}/${x}/test data/local/test_${x,,} data/test_${x,,} || exit 1;
    done 
    # Normalize text to capital letters
    for x in train dev_android dev_ios dev_mic test_android test_ios test_mic; do
        mv data/${x}/text data/${x}/text.org
        paste <(cut -f 1 data/${x}/text.org) <(cut -f 2 data/${x}/text.org | tr '[:lower:]' '[:upper:]') \
            > data/${x}/text
        tools/text2token.py -n 1 -s 1 data/${x}/text > data/${x}/text.org
        mv data/${x}/text.org data/${x}/text
    done
fi

feat_train_dir=${feats_dir}/${dumpdir}/${train_set}; mkdir -p ${feat_train_dir}
feat_dev_dir=${feats_dir}/${dumpdir}/${valid_set}; mkdir -p ${feat_dev_dir}
if [ ${stage} -le 1 ] && [ ${stop_stage} -ge 1 ]; then
    echo "stage 1: Feature Generation"
    # compute fbank features
    fbankdir=${feats_dir}/fbank
    steps/compute_fbank.sh --cmd "$train_cmd" --nj $nj --speed_perturb ${speed_perturb} \
        data/train exp/make_fbank/train ${fbankdir}/train
    tools/fix_data_feat.sh ${fbankdir}/train
    for x in android ios mic; do
        steps/compute_fbank.sh --cmd "$train_cmd" --nj $nj \
            data/dev_${x} exp/make_fbank/dev_${x} ${fbankdir}/dev_${x}
        tools/fix_data_feat.sh ${fbankdir}/dev_${x}
        steps/compute_fbank.sh --cmd "$train_cmd" --nj $nj \
            data/test_${x} exp/make_fbank/test_${x} ${fbankdir}/test_${x}
        tools/fix_data_feat.sh ${fbankdir}/test_${x}
    done
    
    # compute global cmvn
    steps/compute_cmvn.sh --cmd "$train_cmd" --nj $nj \
        ${fbankdir}/train exp/make_fbank/train

    # apply cmvn 
    steps/apply_cmvn.sh --cmd "$train_cmd" --nj $nj \
        ${fbankdir}/${train_set} ${fbankdir}/train/cmvn.json exp/make_fbank/${train_set} ${feat_train_dir}
    steps/apply_cmvn.sh --cmd "$train_cmd" --nj $nj \
        ${fbankdir}/${valid_set} ${fbankdir}/train/cmvn.json exp/make_fbank/${valid_set} ${feat_dev_dir}
    for x in android ios mic; do
        steps/apply_cmvn.sh --cmd "$train_cmd" --nj $nj \
            ${fbankdir}/test_${x} ${fbankdir}/train/cmvn.json exp/make_fbank/test_${x} ${feats_dir}/${dumpdir}/test_${x}
    done
    
    cp ${fbankdir}/${train_set}/text ${fbankdir}/${train_set}/speech_shape ${fbankdir}/${train_set}/text_shape ${feat_train_dir}
    tools/fix_data_feat.sh ${feat_train_dir}
    cp ${fbankdir}/${valid_set}/text ${fbankdir}/${valid_set}/speech_shape ${fbankdir}/${valid_set}/text_shape ${feat_dev_dir}
    tools/fix_data_feat.sh ${feat_dev_dir}
    for x in android ios mic; do
        cp ${fbankdir}/test_${x}/text ${fbankdir}/test_${x}/speech_shape ${fbankdir}/test_${x}/text_shape ${feats_dir}/${dumpdir}/test_${x}
        tools/fix_data_feat.sh ${feats_dir}/${dumpdir}/test_${x}
    done
fi

token_list=${feats_dir}/data/${lang}_token_list/char/tokens.txt
echo "dictionary: ${token_list}"
if [ ${stage} -le 2 ] && [ ${stop_stage} -ge 2 ]; then
    echo "stage 2: Dictionary Preparation"
    mkdir -p data/${lang}_token_list/char/
   
    echo "make a dictionary"
    echo "<blank>" > ${token_list}
    echo "<s>" >> ${token_list}
    echo "</s>" >> ${token_list}
    tools/text2token.py -s 1 -n 1 --space "" data/${train_set}/text | cut -f 2- -d" " | tr " " "\n" \
        | sort | uniq | grep -a -v -e '^\s*$' | awk '{print $0}' >> ${token_list}
    num_token=$(cat ${token_list} | wc -l)
    echo "<unk>" >> ${token_list}
    vocab_size=$(cat ${token_list} | wc -l)
    awk -v v=,${vocab_size} '{print $0v}' ${feat_train_dir}/text_shape > ${feat_train_dir}/text_shape.char
    awk -v v=,${vocab_size} '{print $0v}' ${feat_dev_dir}/text_shape > ${feat_dev_dir}/text_shape.char
    mkdir -p asr_stats_fbank_zh_char/${train_set} 
    mkdir -p asr_stats_fbank_zh_char/${valid_set}
    cp ${feat_train_dir}/speech_shape ${feat_train_dir}/text_shape ${feat_train_dir}/text_shape.char asr_stats_fbank_zh_char/${train_set} 
    cp ${feat_dev_dir}/speech_shape ${feat_dev_dir}/text_shape ${feat_dev_dir}/text_shape.char asr_stats_fbank_zh_char/${valid_set}
fi

# Training Stage
world_size=$gpu_num  # run on one machine
if [ ${stage} -le 3 ] && [ ${stop_stage} -ge 3 ]; then
    echo "stage 3: Training"
    if ! "${skip_extract_embed}"; then
        echo "extract embeddings..."
        local/extract_embeds.sh \
            --bert_model_root ${bert_model_root} \
            --bert_model_name ${bert_model_name} \
            --raw_dataset_path ${feats_dir}
    fi
    mkdir -p ${exp_dir}/exp/${model_dir}
    mkdir -p ${exp_dir}/exp/${model_dir}/log
    INIT_FILE=${exp_dir}/exp/${model_dir}/ddp_init
    if [ -f $INIT_FILE ];then
        rm -f $INIT_FILE
    fi
    init_method=file://$(readlink -f $INIT_FILE)
    echo "$0: init method is $init_method"
    for ((i = 0; i < $gpu_num; ++i)); do
        {
            rank=$i
            local_rank=$i
            gpu_id=$(echo $CUDA_VISIBLE_DEVICES | cut -d',' -f$[$i+1])
            asr_train_paraformer.py \
                --gpu_id $gpu_id \
                --use_preprocessor true \
                --dataset_type $dataset_type \
                --token_type $token_type \
                --token_list $token_list \
                --train_data_file $feats_dir/$dumpdir/${train_set}/data_bert.list \
                --valid_data_file $feats_dir/$dumpdir/${valid_set}/data_bert.list \
                --resume true \
                --output_dir ${exp_dir}/exp/${model_dir} \
                --config $asr_config \
                --allow_variable_data_keys true \
                --input_size $feats_dim \
                --ngpu $gpu_num \
                --num_worker_count $count \
                --multiprocessing_distributed true \
                --dist_init_method $init_method \
                --dist_world_size $world_size \
                --dist_rank $rank \
                --local_rank $local_rank 1> ${exp_dir}/exp/${model_dir}/log/train.log.$i 2>&1
        } &
        done
        wait
fi

# Testing Stage
if [ ${stage} -le 4 ] && [ ${stop_stage} -ge 4 ]; then
    echo "stage 4: Inference"
    for dset in ${test_sets}; do
        asr_exp=${exp_dir}/exp/${model_dir}
        inference_tag="$(basename "${inference_config}" .yaml)"
        _dir="${asr_exp}/${inference_tag}/${inference_asr_model}/${dset}"
        _logdir="${_dir}/logdir"
        if [ -d ${_dir} ]; then
            echo "${_dir} is already exists. if you want to decode again, please delete this dir first."
            exit 0
        fi
        mkdir -p "${_logdir}"
        _data="${feats_dir}/${dumpdir}/${dset}"
        key_file=${_data}/${scp}
        num_scp_file="$(<${key_file} wc -l)"
        _nj=$([ $inference_nj -le $num_scp_file ] && echo "$inference_nj" || echo "$num_scp_file")
        split_scps=
        for n in $(seq "${_nj}"); do
            split_scps+=" ${_logdir}/keys.${n}.scp"
        done
        # shellcheck disable=SC2086
        utils/split_scp.pl "${key_file}" ${split_scps}
        _opts=
        if [ -n "${inference_config}" ]; then
            _opts+="--config ${inference_config} "
        fi
        ${infer_cmd} --gpu "${_ngpu}" --max-jobs-run "${_nj}" JOB=1:"${_nj}" "${_logdir}"/asr_inference.JOB.log \
            python -m funasr.bin.asr_inference_launch \
                --batch_size 1 \
                --ngpu "${_ngpu}" \
                --njob ${njob} \
                --gpuid_list ${gpuid_list} \
                --data_path_and_name_and_type "${_data}/${scp},speech,${type}" \
                --key_file "${_logdir}"/keys.JOB.scp \
                --asr_train_config "${asr_exp}"/config.yaml \
                --asr_model_file "${asr_exp}"/"${inference_asr_model}" \
                --output_dir "${_logdir}"/output.JOB \
                --mode paraformer \
                ${_opts}

        for f in token token_int score text; do
            if [ -f "${_logdir}/output.1/1best_recog/${f}" ]; then
                for i in $(seq "${_nj}"); do
                    cat "${_logdir}/output.${i}/1best_recog/${f}"
                done | sort -k1 >"${_dir}/${f}"
            fi
        done
        python utils/proce_text.py ${_dir}/text ${_dir}/text.proc
        python utils/proce_text.py ${_data}/text ${_data}/text.proc
        python utils/compute_wer.py ${_data}/text.proc ${_dir}/text.proc ${_dir}/text.cer
        tail -n 3 ${_dir}/text.cer > ${_dir}/text.cer.txt
        cat ${_dir}/text.cer.txt
    done
fi

