# intro

This repo contains prototyping work for recoverable tokens.

# todo

- Make an escrow version (disallows spending of unsettled funds, and sender can retract the funds )
- Refine and test the RPool contracts

# get started

## install dependences

- Run `git submodule update --init --recursive` to update/download all libraries.
- Run `nvm use 16` to use node 16.
- Run `yarn install` to install any additional dependencies.

## install foundry

- Run `curl -L https://foundry.paradigm.xyz | bash`
- Follow the instructions of that command to source env file
- run `foundryup`

## Test

`forge test`

## Lint

- Run `yarn lint` to lint all .sol files.
