# Copyright 2019 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Hard-coded platform to `linux/amd64` because
# 1) go mod download is super slow with arm64 on x86 host since it requires QEMU simulation at software level.
# 2) a better approach with `--platform={BUILDPLATFORM}` is only supported by docker buildx not docker build.
FROM --platform=linux/amd64 golang:1.13.4-stretch as builder
WORKDIR /go/src/github.com/kubernetes-sigs/aws-efs-csi-driver

ARG TARGETOS
ARG TARGETARCH
RUN echo "TARGETOS:$TARGETOS, TARGETARCH:$TARGETARCH"
RUN echo "I am running on $(uname -s)/$(uname -m)"

ADD . .

# Default client source is `k8s` which can be overriden with –-build-arg when building the Docker image
ARG client_source=k8s
ENV EFS_CLIENT_SOURCE=$client_source

RUN GOOS=${TARGETOS} GOARCH=${TARGETARCH} make aws-efs-csi-driver

FROM amazonlinux:2
# Install efs-utils from github by default. It can be overriden to `yum` with --build-arg when building the Docker image.
# If value of `EFSUTILSSOURCE` build arg is overriden with `yum`, docker will install efs-utils from Amazon Linux 2's yum repo.
ARG EFSUTILSSOURCE=github
RUN if [ "$EFSUTILSSOURCE" = "yum" ]; \
    then echo "Installing efs-utils from Amazon Linux 2 yum repo" && \
         yum -y install amazon-efs-utils-1.31.1-1.amzn2.noarch; \
    else echo "Installing efs-utils from github using the latest git tag" && \
         yum -y install git rpm-build make && \
         git clone https://github.com/aws/efs-utils && \
         cd efs-utils && \
         git checkout $(git describe --tags $(git rev-list --tags --max-count=1)) && \
         make rpm && yum -y install build/amazon-efs-utils*rpm; \
    fi

# Install botocore required by efs-utils for cross account mount
RUN yum -y install wget
RUN wget https://bootstrap.pypa.io/get-pip.py -O /tmp/get-pip.py
RUN python3 /tmp/get-pip.py
RUN pip3 install botocore || /usr/local/bin/pip3 install botocore

# At image build time, static files installed by efs-utils in the config directory, i.e. CAs file, need
# to be saved in another place so that the other stateful files created at runtime, i.e. private key for
# client certificate, in the same config directory can be persisted to host with a host path volume.
# Otherwise creating a host path volume for that directory will clean up everything inside at the first time.
# Those static files need to be copied back to the config directory when the driver starts up.
RUN mv /etc/amazon/efs /etc/amazon/efs-static-files

COPY --from=builder /go/src/github.com/kubernetes-sigs/aws-efs-csi-driver/bin/aws-efs-csi-driver /bin/aws-efs-csi-driver
COPY THIRD-PARTY /

ENTRYPOINT ["/bin/aws-efs-csi-driver"]
