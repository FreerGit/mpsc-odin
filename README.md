# mpsc-odin
A wait-free Multi producer, single consumer (MPSC) queue. The queue is design in such a way that any data can be attached through polymorphism, structed data aswell as basic types. 

## Usage
Check tests, a multi-threaded example is provided. Remember to carefully read the sync library in std to make sure that your context (specifically allocator) does not break its rules.

## Install
Simply clone and/or copy the `mpsc.odin` file into your project, api is available after that, just like any other odin package.
