set -e

deploymentMode=serverless
while getopts ":hsr" option; do
   case $option in
      h) # display Help
         Help
         exit;;
      r) # skip knative install
	 deploymentMode=kubernetes;;
      s) # install knative
         deploymentMode=serverless;;
     \?) # Invalid option
         echo "Error: Invalid option"
         exit;;
   esac
done

export ISTIO_VERSION=1.17.2
export KNATIVE_SERVING_VERSION=knative-v1.10.1
export KNATIVE_ISTIO_VERSION=knative-v1.10.0
export SCRIPT_DIR="$( dirname -- "${BASH_SOURCE[0]}" )"
export DAPR_VERSION=1.11.2

KUBE_VERSION=$(kubectl version --short=true | grep "Server Version" | awk -F '.' '{print $2}')
if [ ${KUBE_VERSION} -lt 24 ];
then
   echo "😱 install requires at least Kubernetes 1.24";
   exit 1;
fi

curl -L https://istio.io/downloadIstio | sh -
cd istio-${ISTIO_VERSION}

# Create istio-system namespace
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: istio-system
  labels:
    istio-injection: disabled
EOF

cat << EOF > ./istio-minimal-operator.yaml
apiVersion: install.istio.io/v1beta1
kind: IstioOperator
spec:
  values:
    global:
      proxy:
        autoInject: disabled
      useMCP: false

  meshConfig:
    accessLogFile: /dev/stdout

  components:
    ingressGateways:
      - name: istio-ingressgateway
        enabled: true
        k8s:
          service:
            ports: 
            - nodePort: 31080
              port: 80
              targetPort: 8080
          podAnnotations:
            cluster-autoscaler.kubernetes.io/safe-to-evict: "true"
    pilot:
      enabled: true
      k8s:
        resources:
          requests:
            cpu: 200m
            memory: 200Mi
        podAnnotations:
          cluster-autoscaler.kubernetes.io/safe-to-evict: "true"
        env:
        - name: PILOT_ENABLE_CONFIG_DISTRIBUTION_TRACKING
          value: "false"
EOF

bin/istioctl manifest apply -f istio-minimal-operator.yaml -y;

echo "😀 Successfully installed Istio"

# Install Knative
if [ $deploymentMode = serverless ]; then
   kubectl apply --filename https://github.com/knative/serving/releases/download/${KNATIVE_SERVING_VERSION}/serving-crds.yaml
   kubectl apply --filename https://github.com/knative/serving/releases/download/${KNATIVE_SERVING_VERSION}/serving-core.yaml
   kubectl apply --filename https://github.com/knative/net-istio/releases/download/${KNATIVE_ISTIO_VERSION}/release.yaml
   kubectl apply -f https://github.com/knative/serving/releases/download/${KNATIVE_SERVING_VERSION}/serving-default-domain.yaml

   # Patch the external domain as the default domain svc.cluster.local is not exposed on ingress
   kubectl patch configmap -n knative-serving config-domain -p "{\"data\": {\"127.0.0.1.sslip.io\": \"\"}}"
   # Downward APIs and Tag-header-based routing enabled
   kubectl patch cm config-features -n knative-serving -p '{"data":{"tag-header-based-routing":"Enabled", "kubernetes.podspec-fieldref": "Enabled"}}'
   echo "😀 Successfully installed Knative"
fi


# Install Dapr using Helm
helm repo add dapr https://dapr.github.io/helm-charts/

helm repo update

helm upgrade --install dapr dapr/dapr \
--version=${DAPR_VERSION} \
--namespace dapr-system \
--create-namespace \
--wait

# Install Redis
helm upgrade --install conference-redis oci://registry-1.docker.io/bitnamicharts/redis --version 17.11.3 --set "architecture=standalone"

## Install app
helm install app oci://docker.io/salaboy/dapr-example-app --version v1.0.0


# Clean up
rm -rf istio-${ISTIO_VERSION}