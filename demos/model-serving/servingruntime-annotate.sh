#!/usr/bin/env bash
# Makes the RHOAI dashboard name the runtime on its Deployments page.
#
# Without these the page shows "Unknown Serving Runtime" against a model
# that is serving perfectly well. The annotations have to be on the
# ServingRuntime, NOT on the InferenceService - the dashboard resolves the
# runtime, then reads the template annotations off it. `oc process` of the
# template does not add them, because the template describes the runtime
# rather than how the dashboard should label it.
#
# This mirrors "Annotate ServingRuntime for dashboard recognition" in
# ansible/roles/model_serving/tasks/main.yml, which does the same for vLLM.
set -euo pipefail
NS="${1:-rag-eval}"
oc annotate servingruntime mlserver-runtime -n "$NS" \
  opendatahub.io/apiProtocol=REST \
  opendatahub.io/template-name=mlserver-runtime-template \
  opendatahub.io/template-display-name="MLServer ServingRuntime for KServe" \
  --overwrite
