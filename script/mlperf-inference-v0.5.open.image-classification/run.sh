#!/bin/bash

division="open"
task="image-classification"
imagenet_size=50000

scenario="singlestream"
scenario_tag="SingleStream"

# Implementation.
# TODO: Add iteration over implementations and backends. (Now, simply define which one is active.)
implementation_tflite="image-classification-tflite-loadgen"
implementation_armnn="image-classification-armnn-tflite-loadgen"
implementation="${implementation_tflite}"
# ArmNN backends.
implementation_armnn_backend_neon="neon"
implementation_armnn_backend_opencl="opencl"
implementation_armnn_backend=${implementation_armnn_backend_opencl}

# System.
hostname=`hostname`
if [ "${hostname}" = "diviniti" ]; then
  # Assume that host "diviniti" is always used to benchmark Android device "mate10pro".
  system="mate10pro"
  android="--target_os=android24-arm64 --env.CK_LOADGEN_CONF_FILE=user.conf"
elif [ "${hostname}" = "hikey961" ]; then
  system="hikey960"
  android=""
else
  system="${hostname}"
  android=""
fi

# Library.
if [ "${implementation}" == "${implementation_tflite}" ]; then
  if [ "${android}" != "" ]; then
    # NB: Currently, we only support TFLite v1.13 for Android.
    library="tflite-v1.13"
    library_tags="tflite,v1.13"
  else
    library="tflite-v1.15"
    library_tags="tflite,v1.15"
  fi
  armnn_backend=""
elif [ "${implementation}" == ${implementation_armnn} ]; then
  library="armnn-v19.08"
  library_tags="armnn,tflite,neon,opencl,rel.19.08"
  if [ "${system}" = "rpi4" ]; then
    # NB: Force Neon backend on Raspberry Pi 4.
    implementation_armnn_backend="${implementation_armnn_backend_neon}"
  fi
  if [ "${implementation_armnn_backend}" == "${implementation_armnn_backend_opencl}" ]; then
    armnn_backend="--env.USE_OPENCL=1"
  elif [ "${implementation_armnn_backend}" == "${implementation_armnn_backend_neon}" ]; then
    armnn_backend="--env.USE_NEON=1"
  else
    echo "ERROR: Unsupported ArmNN backend '${implementation_armnn_backend}'!"
    exit 1
  fi
else
  echo "ERROR: Unsupported implementation '${implementation}'!"
  exit 1
fi

# Compiler.
if [ "${system}" = "mate10pro" ]; then
  # NB: Currently, we only support Clang 6 (NDK 17c) for Android.
  compiler_tags="llvm,v6"
elif [ "${system}" = "hikey960" ] || [ "${system}" = "firefly" ]; then
  compiler_tags="gcc,v7"
else
  compiler_tags="gcc,v8"
fi

# Image classification models (for the open division).
models=()
models_tags=()
models_preprocessing_tags=()

# Iterate for each model, i.e. resolution and multiplier.
# MobileNet-v1.
version=1
resolutions=( 224 192 160 128 )
multipliers=( 1.0 0.75 0.5 0.25 )
for resolution in ${resolutions[@]}; do
  for multiplier in ${multipliers[@]}; do
#    models+=( "mobilenet-v${version}-${multiplier}-${resolution}" )
#    models_tags+=( "model,tflite,mobilenet,v${version}-${multiplier}-${resolution},non-quantized" )
#    models_preprocessing_tags+=( "side.${resolution},preprocessed,using-opencv" )
    if [ "${implementation}" == "${implementation_tflite}" ]; then
      models+=( "mobilenet-v${version}-${multiplier}-${resolution}-quantized" )
      models_tags+=( "model,tflite,mobilenet,v${version}-${multiplier}-${resolution},quantized" )
      models_preprocessing_tags+=( "side.${resolution},preprocessed,using-opencv" )
    fi
  done
done
## MobileNet-v2.
#version=2
#resolutions=( 224 192 160 128 96 )
#multipliers=( 1.0 0.75 0.5 0.35 )
#for resolution in ${resolutions[@]}; do
#  for multiplier in ${multipliers[@]}; do
#    models+=( "mobilenet-v${version}-${multiplier}-${resolution}" )
#    models_tags+=( "model,tflite,mobilenet,v${version}-${multiplier}-${resolution},non-quantized" )
#    models_preprocessing_tags+=( "side.${resolution},preprocessed,using-opencv" )
#  done
#done
#resolutions=( 224 )
#multipliers=( 1.4 1.3 )
#for resolution in ${resolutions[@]}; do
#  for multiplier in ${multipliers[@]}; do
#    models+=( "mobilenet-v${version}-${multiplier}-${resolution}" )
#    models_tags+=( "model,tflite,mobilenet,v${version}-${multiplier}-${resolution},non-quantized" )
#    models_preprocessing_tags+=( "side.${resolution},preprocessed,using-opencv" )
#  done
#done

#echo "models=( ${models[@]} )"
#echo "models_tags=( ${models_tags[@]} )"
#echo "models_preprocessing_tags=( ${models_preprocessing_tags[@]} )"

# Modes.
modes=( "performance" "accuracy" )
modes_tags=( "PerformanceOnly" "AccuracyOnly" )

# Iterate for each model.
for i in $(seq 1 ${#models[@]}); do
  # Configure the model.
  model=${models[${i}-1]}
  model_tags=${models_tags[${i}-1]}
  model_preprocessing_tags=${models_preprocessing_tags[${i}-1]}
  # Iterate for each mode.
  for j in $(seq 1 ${#modes[@]}); do
    # Configure the mode.
    mode=${modes[${j}-1]}
    mode_tag=${modes_tags[${j}-1]}
    if [ "${mode}" = "accuracy" ]; then
      dataset_size=50000
      buffer_size=500
      verbose=2
    else
      dataset_size=1024
      buffer_size=1024
      verbose=1
    fi
    # Opportunity to skip by mode.
    #if [ "${mode}" != "accuracy" ]; then continue; fi
    # Configure record settings.
    record_uoa="mlperf.${division}.${task}.${system}.${library}"
    record_tags="mlperf,${division},${task},${system},${library}"
    if [ "${implementation}" == "${implementation_armnn}" ]; then
      record_uoa+=".${implementation_armnn_backend}"
      record_tags+=",${implementation_armnn_backend}"
    fi
    record_uoa+=".${model}.${scenario}.${mode}"
    record_tags+=",${model},${scenario},${mode}"
    if [ "${mode}" = "accuracy" ]; then
      # Get substring after "preprocessed," to end.
      preprocessing="${model_preprocessing_tags##*preprocessed,}"
      record_uoa+=".${preprocessing}"
      record_tags+=",${preprocessing}"
    fi
    if [ "${mode}" = "accuracy" ] && [ "${dataset_size}" != "${imagenet_size}" ]; then
      record_uoa+=".${dataset_size}"
      record_tags+=",${dataset_size}"
    fi
    # Run (but before that print the exact command we are about to run).
    echo "Running '${model}' in '${mode}' mode ..."
    read -d '' CMD <<END_OF_CMD
    ck benchmark program:${implementation} \
    --speed --repetitions=1 ${android} ${armnn_backend} \
    --env.CK_VERBOSE=${verbose} \
    --env.CK_LOADGEN_SCENARIO=${scenario_tag} \
    --env.CK_LOADGEN_MODE=${mode_tag} \
    --env.CK_LOADGEN_DATASET_SIZE=${dataset_size} \
    --env.CK_LOADGEN_BUFFER_SIZE=${buffer_size} \
    --dep_add_tags.weights=${model_tags} \
    --dep_add_tags.library=${library_tags} \
    --dep_add_tags.compiler=${compiler_tags} \
    --dep_add_tags.images=${model_preprocessing_tags} \
    --dep_add_tags.python=v3 \
    --record --record_repo=local --record_uoa=${record_uoa} --tags=${record_tags} \
    --skip_print_timers --skip_stat_analysis --process_multi_keys
END_OF_CMD
    echo ${CMD}
    eval ${CMD}
    echo
    # Check for errors.
    if [ "${?}" != "0" ]; then
      echo "ERROR: Failed running '${model}' in '${mode}' mode!"
      exit 1
    fi
  done # for each mode
done # for each model
