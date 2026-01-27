#!/bin/bash
# ~/bin/claude-sandbox

exec podman run --rm -it \
  --device /dev/kfd \
  --device /dev/dri \
  --group-add video \
  --group-add render \
  -e HSA_OVERRIDE_GFX_VERSION="${HSA_OVERRIDE_GFX_VERSION}" \
  -e ROCM_PATH="${ROCM_PATH}" \
  -e HIP_VISIBLE_DEVICES="${HIP_VISIBLE_DEVICES}" \
  -e HOME="$HOME" \
  -e TERM="$TERM" \
  -v /home:/home:ro \
  -v /data:/data:ro \
  -v "$PWD":"$PWD" \
  -w "$PWD" \
  --mount type=tmpfs,dst=/tmp \
  anthropic/claude-code claude --dangerously-skip-permissions "$@"
