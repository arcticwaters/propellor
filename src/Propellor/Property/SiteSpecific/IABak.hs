module Propellor.Property.SiteSpecific.IABak where

import Propellor
import qualified Propellor.Property.Apt as Apt
import qualified Propellor.Property.Git as Git
import qualified Propellor.Property.Cron as Cron
import qualified Propellor.Property.File as File

gitServer :: Property HasInfo
gitServer = propertyList "iabak git server" $ props
	& Git.cloned "root" repo "/usr/local/IA.BAK" (Just "server")
	& Git.cloned "root" repo "/usr/local/IA.BAK/client" (Just "master")
	& Git.cloned "www-data" repo "/usr/local/IA.BAK/pubkeys" (Just "pubkey")
	& Apt.serviceInstalledRunning "apache2"
	& cmdProperty "ln" ["-sf", "/usr/local/IA.BAK/pushme.cgi", "/usr/lib/cgi-bin/pushme.cgi"]
	& File.containsLine "/etc/sudoers" "www-data ALL=NOPASSWD:/usr/local/IA.BAK/pushed.sh"
	& Cron.niceJob "shardstats" (Cron.Times "*/30 * * * *") "root" "/"
		"/usr/local/IA.BAK/shardstats-all"
  where
	repo = "https://github.com/ArchiveTeam/IA.BAK/"

graphiteServer :: Property HasInfo
graphiteServer = propertyList "iabak graphite server" $ props
	& Apt.serviceInstalledRunning "apache2"
	& Apt.installed ["libapache2-mod-wsgi", "graphite-carbon", "graphite-web"]
	& File.hasContent "/etc/carbon/storage-schemas.conf"
		[ "[carbon]"
		, "pattern = ^carbon\\."
		, "retentions = 60:90d"
		, "[iabak]"
		, "pattern = ^iabak\\."
		, "retentions = 10m:30d,1h:1y,3h,10y"
		, "[default_1min_for_1day]"
		, "pattern = .*"
		, "retentions = 60s:1d"
		]
	& graphiteCSRF
	& cmdProperty "graphite-manage" ["syncdb", "--noinput"] `flagFile` "/etc/flagFiles/graphite-syncdb"
	& cmdProperty "graphite-manage" ["createsuperuser", "--noinput", "--username=joey"] `flagFile` "/etc/flagFiles/graphite-user-joey"
	& cmdProperty "graphite-manage" ["createsuperuser", "--noinput", "--username=db48x"] `flagFile` "/etc/flagFiles/graphite-user-db48x"
	-- TODO: deal with passwords somehow
	& File.ownerGroup "/var/lib/graphite/graphite.db" "_graphite" "_graphite"
	& File.hasContent "/etc/apache2/iabak-graphite-web.conf"
		[ "<VirtualHost *:8080>"
		, "        WSGIDaemonProcess _graphite processes=5 threads=5 display-name='%{GROUP}' inactivity-timeout=120 user=_graphite group=_graphite"
		, "        WSGIProcessGroup _graphite"
		, "        WSGIImportScript /usr/share/graphite-web/graphite.wsgi process-group=_graphite application-group=%{GLOBAL}"
		, "        WSGIScriptAlias / /usr/share/graphite-web/graphite.wsgi"
		, "        Alias /content/ /usr/share/graphite-web/static/"
		, "        <Location \"/content/\">"
		, "                SetHandler None"
		, "        </Location>"
		, "        ErrorLog ${APACHE_LOG_DIR}/graphite-web_error.log"
		, "        LogLevel warn"
		, "        CustomLog ${APACHE_LOG_DIR}/graphite-web_access.log combined"
		, "</VirtualHost>"
		]
	& cmdProperty "ln" ["-sf", "/etc/apache2/sites-available/iabak-graphite-web.conf",
	                    "/etc/apache2/sites-enabled/iabak-graphite-web.conf"]
	& Apt.installed ["netcat"]
	& Apt.installed ["tmux"]
	& Apt.installed ["emacs-nox"]
  where
	graphiteCSRF = withPrivData (Password "csrf-token") (Context "iabak.archiveteam.org") $
		\gettoken -> property "graphite-web CSRF token" $
			gettoken $ \token -> ensureProperty $ File.containsLine
				"/etc/graphite/local_settings.py" ("SECRET_KEY = '"++ token ++"'")