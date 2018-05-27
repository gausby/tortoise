# Changelog

## upcoming

- Abstract the network communication into a behaviour called
  `Tortoise.Transport`. This behaviour specify callbacks needed to
  connect, receive, and send messages using a network transport. It
  also specify setting and getting options, as well as listening using
  that network transport; the latter part is done so they can be used
  in integration tests.

- A TCP transport has been created for communicating with a broker
  using TCP.

- A SSL transport has been added to the project allowing us to connect
  to a broker using an encrypted connection.

## 0.1.0 - 2018-05-21

### Added
- The project is now on Hex which will hopefully broaden the user
  base. Future changes will be logged to this file.

- We will from now on update the version number following Semantic
  Versioning, and major changes should get logged to this file.
