# syntax=docker/dockerfile:1-labs
FROM public.ecr.aws/docker/library/alpine:3.21 AS base
ENV TZ=UTC
WORKDIR /src

# source stage =================================================================
FROM base AS source

# get and extract source from git
ARG VERSION
ADD https://github.com/Lidarr/Lidarr/archive/refs/tags/v$VERSION.tar.gz /tmp/source.tgz
RUN tar --strip-components=1 -xf /tmp/source.tgz

# apply available patches
RUN apk add --no-cache patch
COPY patches ./
RUN find ./ -name "*.patch" -print0 | sort -z | xargs -t -0 -n1 patch -p1 -i

# frontend stage ===============================================================
FROM base AS build-frontend

# dependencies
RUN apk add --no-cache yarn

# node_modules
COPY --from=source /src/package.json /src/yarn.lock /src/tsconfig.json ./
RUN yarn install --frozen-lockfile --network-timeout 120000

# frontend source and build
COPY --from=source /src/frontend ./frontend
RUN yarn build --env production --no-stats && \
    find ./ -name "*.map" -type f -delete && \
    mv ./_output/UI /build

# normalize arch ===============================================================
FROM base AS base-arm64
ENV RUNTIME=linux-musl-arm64
FROM base AS base-amd64
ENV RUNTIME=linux-musl-x64

# backend stage ================================================================
FROM base-$TARGETARCH AS build-backend

# dependencies
RUN apk add --no-cache dotnet6-sdk --repository=https://dl-cdn.alpinelinux.org/alpine/edge/testing

# dotnet source
COPY --from=source /src/.editorconfig ./
COPY --from=source /src/Logo ./Logo
COPY --from=source /src/src ./src

# build backend
ARG BRANCH
ARG VERSION
RUN dotnet build ./src/Lidarr.sln \
        -p:AssemblyConfiguration="$BRANCH" \
        -p:AssemblyVersion="$VERSION" \
        -p:RuntimeIdentifiers="$RUNTIME" \
        -p:Configuration=Release \
        -p:SelfContained=false \
        -t:PublishAllRids && \
    find ./ \( \
        -name "ServiceUninstall.*" -o \
        -name "ServiceInstall.*" -o \
        -name "Lidarr.Windows.*" \
    \) | xargs rm -rf && \
    mkdir /build && mv ./_output/net6.0/$RUNTIME/publish /build/bin && \
    chmod +x /build/bin/fpcalc

# versioning (runtime)
ARG COMMIT=$VERSION
COPY <<EOF /build/package_info
PackageAuthor=[fabricionaweb](https://github.com/fabricionaweb/docker-lidarr)
UpdateMethod=Docker
Branch=$BRANCH
PackageVersion=$COMMIT
EOF

# runtime stage ================================================================
FROM base

ENV S6_VERBOSITY=0 S6_BEHAVIOUR_IF_STAGE2_FAILS=2 PUID=65534 PGID=65534
WORKDIR /config
VOLUME /config
EXPOSE 8686

# copy files
COPY --from=build-backend /build /app
COPY --from=build-frontend /build /app/bin/UI
COPY ./rootfs/. /

# runtime dependencies
RUN apk add --no-cache tzdata s6-overlay sqlite-libs curl && \
    apk add --no-cache aspnetcore6-runtime --repository=https://dl-cdn.alpinelinux.org/alpine/edge/testing

# run using s6-overlay
ENTRYPOINT ["/init"]
