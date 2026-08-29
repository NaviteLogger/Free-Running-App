FROM node:24

ARG TZ
ENV TZ="$TZ"

ARG CLAUDE_CODE_VERSION=latest

RUN apt-get update && apt-get install -y --no-install-recommends \
  less \
  git \
  procps \
  sudo \
  fzf \
  zsh \
  man-db \
  unzip \
  gnupg2 \
  gh \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  jq \
  nano \
  vim \
  ca-certificates \
  curl \
  file \
  xz-utils \
  zip \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /usr/local/share/npm-global && \
  chown -R node:node /usr/local/share

ARG USERNAME=node

RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  && mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R $USERNAME /commandhistory

ENV DEVCONTAINER=true

RUN mkdir -p /workspace /home/node/.claude /home/node/.gradle && \
  chown -R node:node /workspace /home/node/.claude /home/node/.gradle

WORKDIR /workspace

ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  sudo dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

ENV JAVA_HOME=/opt/java
ARG JAVA_VERSION=21
RUN mkdir -p "$JAVA_HOME" && \
  wget -qO /tmp/jdk.tar.gz "https://api.adoptium.net/v3/binary/latest/${JAVA_VERSION}/ga/linux/x64/jdk/hotspot/normal/eclipse" && \
  tar -xzf /tmp/jdk.tar.gz -C "$JAVA_HOME" --strip-components=1 && \
  rm /tmp/jdk.tar.gz
ENV PATH=$JAVA_HOME/bin:$PATH

ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=$ANDROID_HOME
ARG ANDROID_BOOTSTRAP_TOOLS_VERSION=11076708
RUN mkdir -p "$ANDROID_HOME/cmdline-tools" && \
  wget -qO /tmp/cmdline-tools.zip \
    "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_BOOTSTRAP_TOOLS_VERSION}_latest.zip" && \
  unzip -q /tmp/cmdline-tools.zip -d "$ANDROID_HOME/cmdline-tools" && \
  mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/bootstrap" && \
  rm /tmp/cmdline-tools.zip && \
  chown -R node:node "$ANDROID_HOME"
ENV PATH=$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/cmdline-tools/bootstrap/bin:$ANDROID_HOME/platform-tools:$PATH

USER node

RUN set -eux; \
  yes | sdkmanager --licenses > /dev/null; \
  sdkmanager --install "cmdline-tools;latest" "platform-tools" > /dev/null; \
  SDK_PATHS="$(sdkmanager --list 2>/dev/null | awk -F"|" 'NF>1 {gsub(/[[:space:]]/,"",$1); print $1}')"; \
  PLATFORM="$(echo "$SDK_PATHS" | grep -E '^platforms;android-[0-9]+$' | sort -u -t- -k2 -n | tail -1)"; \
  BUILD_TOOLS="$(echo "$SDK_PATHS" | grep -E '^build-tools;[0-9]+\.[0-9]+\.[0-9]+$' | sort -u -V | tail -1)"; \
  test -n "$PLATFORM"; \
  test -n "$BUILD_TOOLS"; \
  echo "Resolved: $PLATFORM / $BUILD_TOOLS"; \
  sdkmanager --install "$PLATFORM" "$BUILD_TOOLS" > /dev/null

ENV FLUTTER_ROOT=/home/node/flutter
ENV PUB_CACHE=/home/node/.pub-cache
ENV PATH=$FLUTTER_ROOT/bin:$PUB_CACHE/bin:$PATH
ARG FLUTTER_CHANNEL=stable
RUN git clone --depth 1 --branch "$FLUTTER_CHANNEL" https://github.com/flutter/flutter.git "$FLUTTER_ROOT" && \
  git config --global --add safe.directory "$FLUTTER_ROOT" && \
  (flutter config --no-analytics --no-enable-web \
    --no-enable-linux-desktop --no-enable-macos-desktop --no-enable-windows-desktop || true) && \
  (dart --disable-analytics || true) && \
  flutter precache --android --no-ios && \
  (flutter doctor -v || true)

ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin
ENV SHELL=/bin/zsh
ENV EDITOR=nano
ENV VISUAL=nano

ARG ZSH_IN_DOCKER_VERSION=1.2.0
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
  -p git \
  -p fzf \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
  -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  -x

RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}
USER root
RUN echo "node ALL=(root) NOPASSWD:ALL" > /etc/sudoers.d/node && chmod 0440 /etc/sudoers.d/node
USER node