# Publishing Messages

Tortoise provide a couple of methods for publishing messages to a MQTT
broker. They very in the amount of setup needed to setup a publish,
and they differ in the way connection drops are handled.

This document will describe the different supported ways of publishing
messages, and should serve as a guide for when to choose a particular
strategy and their setup. All publish methods require an open
connection.

## `Tortoise.publish/4`

The simplest way of publishing a message is to use the `publish`
function found on the main `Tortoise` module. Given the identifier of
a connection
