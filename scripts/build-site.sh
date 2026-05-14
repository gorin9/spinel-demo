#!/bin/bash
# /site/* (SiteController + Router + ERB) のビルドツール 3 連発
# 1) spnl-erb で views/site/*.erb -> *.generated.rb
# 2) spnl-router で app/site_controller.rb -> app/site_router.generated.rb
set -euo pipefail
cd "$(dirname "$0")/.."

SPNL_ERB=${SPNL_ERB:-../spnl-erb-repo/bin/spnl-erb}
SPNL_ROUTER=${SPNL_ROUTER:-../spnl-router-repo/bin/spnl-router}
RUBY=${RUBY:-ruby}

echo "==> spnl-erb (3 templates → site_controller reopen)"

$RUBY $SPNL_ERB views/site/layout.html.erb \
  --mode controller --target SiteController \
  -m render_layout \
  -o views/site/layout.html.generated.rb

$RUBY $SPNL_ERB views/site/home.html.erb \
  --mode controller --target SiteController \
  -m render_home \
  -o views/site/home.html.generated.rb

$RUBY $SPNL_ERB views/site/users.html.erb \
  --mode controller --target SiteController \
  -m render_users \
  -o views/site/users.html.generated.rb

echo "==> spnl-router (SiteController → SiteRouter dispatcher)"

$RUBY $SPNL_ROUTER app/site_controller.rb \
  --module-name SiteRouter \
  -o app/site_router.generated.rb

echo "==> Done."
ls -la views/site/*.generated.rb app/site_router.generated.rb
