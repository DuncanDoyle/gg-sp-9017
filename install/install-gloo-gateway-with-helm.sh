#!/bin/sh

export GLOO_GATEWAY_VERSION="1.21.3"
export GLOO_GATEWAY_HELM_VALUES_FILE="gloo-gateway-helm-values.yaml"

if [ -z "$GLOO_GATEWAY_LICENSE_KEY" ]
then
   echo "Gloo Gateway License Key not specified. Please configure the environment variable 'GLOO_GATEWAY_LICENSE_KEY' with your Gloo Gateway License Key."
   exit 1
fi

#----------------------------------------- Install Gloo Gateway (Edge API) -----------------------------------------

helm upgrade --install gloo glooe/gloo-ee --namespace gloo-system --create-namespace --set-string license_key=$GLOO_GATEWAY_LICENSE_KEY -f $GLOO_GATEWAY_HELM_VALUES_FILE --version $GLOO_GATEWAY_VERSION
