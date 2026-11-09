#!/bin/sh
set -eu
ruby scripts/generate.rb
git diff --exit-code -- app/models/user.generated.rb app/site_router.generated.rb views/site/ sig/
