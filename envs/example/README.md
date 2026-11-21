# Environment "example"

This is a template. It uses the ffbs gateways and topology with a Gluon image
that you supply.

1. Put an x86-64 Gluon image into `gluon/`, or set `GLUON_IMAGE_URL`.
2. Run `./lab.sh -e example build`, then `./lab.sh -e example deploy`.
3. Run `./lab.sh -e example test`.

To make a new environment, copy this directory to `envs/NAME` and change
`env.conf`. Refer to [docs/environments.md](../../docs/environments.md).
