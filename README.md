# Recoverable Wrapper Tokens

Developed by [Circle Research](https://www.circle.com/en/circle-research), the recoverable wrapper token (RWT) is a configurable mechanism for wrapping
around ERC-20 tokens to support asset recovery within a limited time window after an asset transfer. For more information, see the [whitepaper](https://www.circle.com/hubfs/Circle%20Research/Whitepapers/Recoverable_Wrapper_Tokens_Circle_Research.pdf).

This repo contains an [audited](https://github.com/circlefin/recoverable-wrapper/tree/master/audit) implementation (configuration 1) of recoverable wrapper tokens.

# Development and contribution

## Install dependencies

- Run `git submodule update --init --recursive` to update/download all libraries.
- Run `nvm use 16` to use node 16.
- Run `yarn install` to install any additional dependencies.

## Install foundry

- Run `curl -L https://foundry.paradigm.xyz | bash`
- Follow the instructions of that command to source env file
- run `foundryup`

## Test

`forge test`

## Lint

- Run `yarn lint` to lint all .sol files.
