FROM centos:centos7.3.1611

RUN yum install -y \
  git \
  wget && \
  yum clean all

# install and setup go
RUN \
  VER="1.9.5"; \
  ARCH="linux-amd64"; \
  FILE="go${VER}.${ARCH}.tar.gz"; \
  HASH="d21bdabf4272c2248c41b45cec606844bdc5c7c04240899bde36c01a28c51ee7"; \
  \
  wget -nv -O "$FILE" "https://golang.org/dl/$FILE"; \
  printf "%s %s" "$HASH" "$FILE" | sha256sum -c -; \
  tar -C /usr/local -xzf "$FILE"; \
  \
  rm "$FILE"; \
  export PATH="/usr/local/go/bin:$PATH"; \
  go version

ENV GOPATH /go
ENV GOROOT /usr/local/go
ENV PATH $GOPATH/bin:$GOROOT/bin:$PATH

RUN mkdir -p "$GOPATH/src" "$GOPATH/bin"

# code coverage conversion dependencies
RUN go get \
  github.com/axw/gocov/gocov \
  github.com/AlekSi/gocov-xml \
  github.com/tebeka/go2xunit

# construct a build path for gots
ENV GOTS_PATH $GOPATH/src/github.com/Comcast/gots

# copy the project into the container
RUN mkdir -p "$GOTS_PATH"
COPY . $GOTS_PATH/

RUN GOTS_PATH=$GOTS_PATH

# run the build script inside the newly created container
WORKDIR $GOTS_PATH
RUN ./build/jenkins-build.sh

