# Hard Links on Google Cloud Run: Issue Observed

## Overview

GCR (Google Cloud Run) seems to handle hard links incorrectly as of now. For hard-linked files (assuming two) in a docker image used by GCR to create a container, there are two types of issues observed:
- Type 1: Both files still exist but are no longer linked. (default build)
- Type 2: Only one file survives as the other simply disappears. (kaniko build)

Without further experiments or information yet, it is assumed that the issue comes from Google Cloud's choice (and possibly customization) of storage driver.

## Preparation

This repository contains sufficient configuration to reproduce both types of the described issues as of today.

Here is a sample Dockerfile used for illustrational purposes:

```dockerfile
FROM ubuntu:20.04 AS base
RUN apt-get update && apt-get install -y gawk socat
WORKDIR /app
RUN echo foo > testfile && ln testfile testfile_2
RUN ls -lah /app/
RUN grep -H . *
RUN find /app/ -type f -printf '%i %p\n'
CMD socat -T1 TCP-LISTEN:8080,crlf,fork,reuseaddr SYSTEM:"echo 'HTTP/1.1 200 OK' && echo 'Connection: close' && echo && stdbuf -oL awk \'{if(body)print;body+=\!\$0}\' | bash",pty,echo=0,raw
```

This docker file prepares two files (`testfile` and `testfile_2`) that are hard-linked, then runs a few simple commands to inspect the state during building time.

The `CMD` entry is nothing more than a quick trick to execute arbitrary commands provided in an HTTP request's body and return the result via the corresponding HTTP response. This helps the user inspect the container's state when running on GCR.

## Type 1: Both files still exist but are no longer linked. (default build)

This type of issue may be reproduced using Google Cloud's default builder.

#### Sample build command

```
$ gcloud builds submit --tag gcr.io/foo-project/tmp-test/default-build
```

#### Debugging outputs during the build

```
Step 5/8 : RUN ls -lah /app/
 ---> Running in 6e6bbf1f1830
total 16K
drwxr-xr-x 1 root root 4.0K Jul 12 23:35 .
drwxr-xr-x 1 root root 4.0K Jul 12 23:35 ..
-rw-r--r-- 2 root root    4 Jul 12 23:35 testfile
-rw-r--r-- 2 root root    4 Jul 12 23:35 testfile_2

Step 6/8 : RUN grep -H . *
 ---> Running in 8853be2c24df
testfile:foo
testfile_2:foo

Step 7/8 : RUN find /app/ -type f -printf '%i %p\n'
 ---> Running in 1faf52ce457a
1295796 /app/testfile
1295796 /app/testfile_2
```

Above is the debugging lines generated during the build (some irrelevant lines omitted). That meets all our expectations: both files exist, their contents are okay, and they are hard-linked.

#### Sample deployment command for GCR

```
$ gcloud run deploy tmp-test-foo-service --region=us-east1 --image=gcr.io/foo-project/tmp-test/default-build:latest --port=8080 --ingress=internal --allow-unauthenticated
```

#### Inspection results from the service on GCR

```
$ curl $TMP_TEST_URL --data $'ls -lah\n'
total 0
drwxr-xr-x 2 root root 0 Jul 12 23:35 .
drwxr-xr-x 1 root root 0 Jul 12 23:39 ..
-rw-r--r-- 1 root root 4 Jul 12 23:35 testfile
-rw-r--r-- 1 root root 4 Jul 12 23:35 testfile_2

$ curl $TMP_TEST_URL --data $'grep -H . *\n'
testfile:foo
testfile_2:foo

$ curl $TMP_TEST_URL --data $'find /app/ -type f -printf \'%i %p\n\'\n'
250 /app/testfile
251 /app/testfile_2
```
Both files still exist and the contents are okay. However they are no longer hard-linked as seen in the running container and this might cause issues.

#### Alternative results from my local machine

An alternative approach was attempted by pulling the earlier built docker image from Google Cloud and launching it locally. Here's the sample command for doing so:
```
$ docker run --rm -it -p 8080:8080 gcr.io/foo-project/tmp-test/default-build:latest
```

Below are results for the same inspections, which this time suggest that the two files do share the same inode.

```
$ curl localhost:8080 --data $'ls -lah\n'
total 8.0K
drwxr-xr-x  2 root root  40 Jul 12 23:35 .
drwxr-xr-x 18 root root 280 Jul 12 23:43 ..
-rw-r--r--  2 root root   4 Jul 12 23:35 testfile
-rw-r--r--  2 root root   4 Jul 12 23:35 testfile_2

$ curl localhost:8080 --data $'grep -H . *\n'
testfile:foo
testfile_2:foo

$ curl localhost:8080 --data $'find /app/ -type f -printf \'%i %p\n\'\n'
4194620 /app/testfile
4194620 /app/testfile_2
```

## Type 2: Only one file survives as the other simply disappears. (kaniko build)

This type of issue is observed to happen when using a [community builder](https://cloud.google.com/build/docs/cloud-builders#community-contributed_builders) called [kaniko](https://github.com/GoogleContainerTools/kaniko).

Here is content of a configuration file `cloudbuild-kaniko.yaml` for the build:
```yaml
steps:
- name: 'gcr.io/kaniko-project/executor:latest'
  args:
  - --destination=gcr.io/foo-project/tmp-test/kaniko-build:latest
```

#### Sample build command

```
$ gcloud builds submit --config cloudbuild-kaniko.yaml
```

#### Debugging outputs during the build

```
INFO[0012] Running: [/bin/sh -c ls -lah /app/]          
total 16K
drwxr-xr-x 2 root root 4.0K Jul 12 23:52 .
drwxr-xr-x 1 root root 4.0K Jul 12 23:52 ..
-rw-r--r-- 2 root root    4 Jul 12 23:52 testfile
-rw-r--r-- 2 root root    4 Jul 12 23:52 testfile_2

INFO[0012] Running: [/bin/sh -c grep -H . *]            
testfile:foo
testfile_2:foo

INFO[0012] Running: [/bin/sh -c find /app/ -type f -printf '%i %p\n']
1298486 /app/testfile
1298486 /app/testfile_2
```
Above are the debugging lines generated during the build (some irrelevant lines omitted). That still looks good as both files exist, their contents are okay, and they are hard-linked.

#### Sample deployment command for GCR

```
$ gcloud run deploy tmp-test-foo-service --region=us-east1 --image=gcr.io/foo-project/tmp-test/kaniko-build:latest --port=8080 --ingress=internal --allow-unauthenticated
```

#### Inspection results from the service on GCR

```
$ curl $TMP_TEST_URL --data $'ls -lah\n'
total 0
drwxr-xr-x 2 root root 0 Jul 12 23:52 .
drwxr-xr-x 1 root root 0 Jul 12 23:54 ..
-rw-r--r-- 1 root root 4 Jul 12 23:52 testfile

$ curl $TMP_TEST_URL --data $'grep -H . *\n'
testfile:foo

$ curl $TMP_TEST_URL --data $'find /app/ -type f -printf \'%i %p\n\'\n'
203 /app/testfile
```
This immediately looks wrong as one of the two files simply disappears.

#### Alternative results from my local machine

Again I tried to pull the previously built image locally and launch the same service:
```
$ docker run --rm -it -p 8080:8080 gcr.io/foo-project/tmp-test/kaniko-build:latest
```

Still, it looks fine when running on my local machine:
```
$ curl localhost:8080 --data $'ls -lah\n'
total 8.0K
drwxr-xr-x  2 root root  40 Jul 12 23:52 .
drwxr-xr-x 18 root root 280 Jul 12 23:57 ..
-rw-r--r--  2 root root   4 Jul 12 23:52 testfile
-rw-r--r--  2 root root   4 Jul 12 23:52 testfile_2

$ curl localhost:8080 --data $'grep -H . *\n'
testfile:foo
testfile_2:foo

$ curl localhost:8080 --data $'find /app/ -type f -printf \'%i %p\n\'\n'
4194620 /app/testfile
4194620 /app/testfile_2
```