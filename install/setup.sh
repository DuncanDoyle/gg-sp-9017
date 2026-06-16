#!/bin/sh

pushd ..

# Create namespaces
kubectl create namespace httpbin --dry-run=client -o yaml | kubectl apply -f -

# Deploy the Edge API Gateway
printf "\nDeploy Edge API Gateway ...\n"
kubectl apply -f gateways/gateway-proxy.yaml

# Deploy the HTTPBin application
printf "\nDeploy HTTPBin application ...\n"
kubectl apply -f apis/httpbin.yaml

# Deploy the failing-jwks upstream (required by Gloo's JWT plugin)
printf "\nDeploy failing-jwks Upstream ...\n"
kubectl apply -f upstreams/failing-jwks-upstream.yaml

# Deploy the initial VirtualService with JWT asyncFetch (svc-001 only).
# svc-002 is applied manually via test.sh to demonstrate the timer leak.
printf "\nDeploy initial VirtualService (svc-001) ...\n"
kubectl apply -f virtualservices/svc-001-vs.yaml

popd
