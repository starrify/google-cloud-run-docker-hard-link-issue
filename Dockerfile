FROM ubuntu:20.04 AS base
RUN apt-get update && apt-get install -y gawk socat
WORKDIR /app
RUN echo foo > testfile && ln testfile testfile_2
RUN ls -lah /app/
RUN grep -H . *
RUN find /app/ -type f -printf '%i %p\n'
CMD socat -T1 TCP-LISTEN:8080,crlf,fork,reuseaddr SYSTEM:"echo 'HTTP/1.1 200 OK' && echo 'Connection: close' && echo && stdbuf -oL awk \'{if(body)print;body+=\!\$0}\' | bash",pty,echo=0,raw
