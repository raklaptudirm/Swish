= Swish Vision Statement

Swish is supposed to be an implementation of an embeddable Swift interpreter at its very core. The exact implementation details are inspired by the state-of-the-art embedded language implmentations available such as Lua, Lisp, etc, changed to suit the Swift programming language.

The interpreter should eventually support arbitrary Swift code and libraries, ideally achieving parity with the compiler: a compiled swift package and the interpreter boxed into an executable should behave the same, sans maybe speed for obvious reasons. This involves a balance between bridging and interpreting source directly, depending on what helps achieve the other goals.

The Swish Shell is a client of the embedded interpreter. It extends the language's syntax by adding sugar for many shell constructs, but they are only that -- sugar. Everything transpiles to a valid Swift AST and is hence run with the interpreter, which as mentioned can run arbitrary Swift code. The code that the sugar unsugars to and the functionality expected of the shell is implemented though sugar and the SwishStandardLibrary, which is a Swift library containing shell constructs loaded in the interpreter used by the shell, no special casing.

It might be pertinant to split the project into two: the embedded interpreter and the shell, which becomes a client of the former.