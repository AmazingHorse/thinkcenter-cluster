set shell := ["bash", "-euo", "pipefail", "-c"]
set allow-duplicate-recipes
set positional-arguments

default:
    @just --list

# Earlier imports win in just 1.58: project > archetype > base.
import? 'project.just'
import? 'archetype.just'
import '.config/just/base.just'
