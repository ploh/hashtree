# Hashtree
Proof of concept for the *hashtree* algorithm - developed as part of a joint research project on *IT-ecosystems*

## Problem
* Given:
 * Distributed system with not-well-connected clients, e.g. laptops of business travellers
 * Large collection of files that is initially setup identically on all clients, e.g. media collection
* Task:
 * Sync modifications of the file collection, e.g. when two travellers meet

## Algorithm
1. On each client:
 1. Identify each file by its hash value - files are the leafs of the tree
 1. Compute a hash for each X hashes - this is the parent node of the X file nodes
 1. Recursively continue until you have only one hash - the tree root
1. For comparison of clients' collections:
 1. Compare root hash
 1. If different, compare all direct childrens' hashes
 1. Continue until you have found all different files

## Usage
Just run `./hashtree.rb` to run the test cases
