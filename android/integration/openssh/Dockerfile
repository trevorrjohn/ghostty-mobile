FROM alpine:3.22@sha256:310c62b5e7ca5b08167e4384c68db0fd2905dd9c7493756d356e893909057601

RUN apk add --no-cache openssh-server=10.0_p1-r10 \
    && adduser -D -h /home/ghostty -s /bin/sh ghostty \
    && printf '%s\n' 'ghostty:ghostty-test-password' | chpasswd \
    && mkdir -p /run/sshd /home/ghostty/files \
    && printf '%s\n' 'disposable ssh fixture' > /home/ghostty/files/welcome.txt \
    && chown -R ghostty:ghostty /home/ghostty \
    && ssh-keygen -A

COPY sshd_config /etc/ssh/sshd_config

EXPOSE 22

CMD ["/usr/sbin/sshd", "-D", "-e", "-f", "/etc/ssh/sshd_config"]
