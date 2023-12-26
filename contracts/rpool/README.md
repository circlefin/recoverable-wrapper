# RPools Background

We argue that many DeFi services will likely refuse to accept unsettled recoverable assets because they can interfere with their normal operations. Consequently, when Alice receives an ERC20R token, she must wait 24 hours before she can use it with a DeFi service. But what if Alice is willing to pay a fee to exchange the wrapped token for an unwrapped ERC20 token that can be used right away?

This repo provides sample implementations of an RPool, which is a pool designed to exchange an unsettled ERC20R asset for a base ERC20 of the same asset.
One version is an AMM and one version is an order-book. 
## Paper

[Full paper](https://arxiv.org/pdf/2312.14375.pdf)
