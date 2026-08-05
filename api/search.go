package api

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/anacrolix/missinggo/perf"
	"github.com/asdine/storm/q"
	"github.com/cespare/xxhash"
	"github.com/gin-gonic/gin"
	"github.com/op/go-logging"

	"github.com/elgatito/elementum/bittorrent"
	"github.com/elgatito/elementum/config"
	"github.com/elgatito/elementum/database"
	"github.com/elgatito/elementum/providers"
	"github.com/elgatito/elementum/util"
	"github.com/elgatito/elementum/xbmc"
)

var searchLog = logging.MustGetLogger("search")

// Search ...
func Search(s *bittorrent.Service) gin.HandlerFunc {
	return func(ctx *gin.Context) {
		defer perf.ScopeTimer()()

		xbmcHost, _ := xbmc.GetXBMCHostWithContext(ctx)
		if xbmcHost == nil {
			return
		}

		query := ctx.Query("q")
		keyboard := ctx.Query("keyboard")
		action := ctx.Query("action")
		silent := ctx.DefaultQuery("silent", "")
		index := ctx.DefaultQuery("index", "")
		historyType := ""

		runAction := "/play"
		if action == "download" {
			runAction = "/download"
		}

		if len(query) == 0 {
			searchHistoryProcess(ctx, historyType, keyboard)
			return
		}

		// Update query last use date to show it on the top
		database.GetStorm().AddSearchHistory(historyType, query)

		fakeTmdbID := strconv.Itoa(int(xxhash.Sum64String(query)))
		existingTorrent := s.HasTorrentByQuery(query)
		if existingTorrent != nil && (silent != "" || config.Get().SilentStreamStart || existingTorrent.IsPlaying || (existingTorrent.IsNextFile && config.Get().SmartEpisodeChoose) || xbmcHost.DialogConfirmFocused("Elementum", fmt.Sprintf("LOCALIZE[30608];;[B]%s[/B]", existingTorrent.Title()))) {
			xbmcHost.PlayURLWithTimeout(URLQuery(
				URLForXBMC(runAction),
				"resume", existingTorrent.InfoHash(),
				"query", query,
				"tmdb", fakeTmdbID,
				"index", index,
				"type", "search"))
			return
		}

		if torrent := InTorrentsMap(xbmcHost, fakeTmdbID); torrent != nil {
			xbmcHost.PlayURLWithTimeout(URLQuery(
				URLForXBMC(runAction), "uri", torrent.URI,
				"query", query,
				"tmdb", fakeTmdbID,
				"index", index,
				"type", "search"))
			return
		}

		var torrents []*bittorrent.TorrentFile
		var err error
		choice := -1
		usedProgressiveDialog := false
		playAction := detectPlayAction("", searchType)

		if torrents, err = GetCachedTorrents(fakeTmdbID); err != nil || len(torrents) == 0 {
			if playAction == "play" {
				torrents = searchLinks(xbmcHost, ctx.Request.Host, query)
			} else {
				usedProgressiveDialog = true
				torrents, choice = selectProgressiveMovie(
					xbmcHost,
					query,
					searchLinksProgressive(xbmcHost, ctx.Request.Host, query),
				)
			}

			SetCachedTorrents(fakeTmdbID, torrents)
		}

		if len(torrents) == 0 {
			xbmcHost.Notify("Elementum", "LOCALIZE[30205]", config.AddonIcon())
			return
		}

		if !usedProgressiveDialog {
			if playAction == "play" {
				choice = 0
			} else {
				choice = xbmcHost.ListDialogLarge("LOCALIZE[30228]", query, movieTorrentChoices(torrents)...)
			}
		}

		if choice >= 0 {
			AddToTorrentsMap(fakeTmdbID, torrents[choice])

			xbmcHost.PlayURLWithTimeout(URLQuery(
				URLForXBMC(runAction),
				"uri", torrents[choice].URI,
				"query", query,
				"tmdb", fakeTmdbID,
				"index", index,
				"type", "search"))
			return
		}
	}
}

func searchLinks(xbmcHost *xbmc.XBMCHost, callbackHost string, query string) []*bittorrent.TorrentFile {
	searchLog.Infof("Searching providers for query: %s", query)

	searchers := providers.GetSearchers(xbmcHost, callbackHost)
	if len(searchers) == 0 {
		xbmcHost.Notify("Elementum", "LOCALIZE[30204]", config.AddonIcon())
	}

	return providers.Search(xbmcHost, searchers, query)
}

func searchLinksProgressive(xbmcHost *xbmc.XBMCHost, callbackHost string, query string) <-chan []*bittorrent.TorrentFile {
	searchLog.Infof("Searching providers progressively for query: %s", query)

	searchers := providers.GetSearchers(xbmcHost, callbackHost)
	if len(searchers) == 0 {
		xbmcHost.Notify("Elementum", "LOCALIZE[30204]", config.AddonIcon())
		empty := make(chan []*bittorrent.TorrentFile)
		close(empty)
		return empty
	}

	return providers.SearchProgressive(xbmcHost, searchers, query)
}

func searchHistoryProcess(ctx *gin.Context, historyType string, keyboard string) {
	xbmcHost, _ := xbmc.GetXBMCHostWithContext(ctx)
	if xbmcHost == nil {
		return
	}

	if len(keyboard) > 0 {
		query := ""
		if query = xbmcHost.Keyboard("", "LOCALIZE[30206]"); len(query) == 0 {
			return
		}
		searchHistoryAppend(ctx, historyType, query)
	} else {
		searchHistoryList(ctx, historyType)
	}
}

func searchHistoryAppend(ctx *gin.Context, historyType string, query string) {
	xbmcHost, _ := xbmc.GetXBMCHostWithContext(ctx)
	if xbmcHost == nil {
		return
	}

	database.GetStorm().AddSearchHistory(historyType, query)

	go xbmcHost.UpdatePath(searchHistoryGetXbmcURL(historyType, query))
	ctx.String(200, "")
}

func searchHistoryList(ctx *gin.Context, historyType string) {
	historyList := []string{}
	var qs []database.QueryHistory
	if err := database.GetStormDB().Select(q.Eq("Type", historyType)).OrderBy("Dt").Reverse().Find(&qs); err == nil {
		for _, q := range qs {
			historyList = append(historyList, q.Query)
		}
	}

	urlPrefix := ""
	if len(historyType) > 0 {
		urlPrefix = "/" + historyType
	}

	items := xbmc.ListItems{
		{Label: "LOCALIZE[30209]", Path: URLForXBMC(urlPrefix+"/search") + "?keyboard=1", Thumbnail: config.AddonResource("img", "search.png")},
	}

	for _, query := range historyList {
		items = append(items, &xbmc.ListItem{
			Label: query,
			Path:  searchHistoryGetXbmcURL(historyType, query),
			ContextMenu: [][]string{
				{"LOCALIZE[30316]", fmt.Sprintf("RunPlugin(%s)", URLQuery(URLForXBMC("/search/remove"), "q", query, "type", historyType))},
			},
		})
	}

	ctx.JSON(200, xbmc.NewView("", items))
}

func searchHistoryGetXbmcURL(historyType string, query string) string {
	urlPrefix := ""
	if len(historyType) > 0 {
		urlPrefix = "/" + historyType
	}
	return URLQuery(URLForXBMC(urlPrefix+"/search"), "q", strings.TrimSpace(query))
}

// SearchRemove ...
func SearchRemove(ctx *gin.Context) {
	query := ctx.Query("q")
	historyType := ctx.Query("type")
	if query == "" {
		return
	}

	database.GetStorm().RemoveSearchHistory(historyType, query)
	xbmcHost, _ := xbmc.GetXBMCHostWithContext(ctx)
	if xbmcHost != nil {
		xbmcHost.Refresh()
	}
}
