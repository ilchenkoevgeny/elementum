package providers

import (
	"github.com/anacrolix/sync"

	"github.com/elgatito/elementum/bittorrent"
	"github.com/elgatito/elementum/xbmc"
)

// SearchProgressive resolves and emits a complete, seed-sorted snapshot
// whenever a general-search provider returns another batch.
func SearchProgressive(xbmcHost *xbmc.XBMCHost, searchers []Searcher, query string) <-chan []*bittorrent.TorrentFile {
	updates := make(chan []*bittorrent.TorrentFile, 8)
	rawBatches := make(chan []*bittorrent.TorrentFile, 8)

	go func() {
		wg := sync.WaitGroup{}
		for _, searcher := range searchers {
			wg.Add(1)
			go func(searcher Searcher) {
				defer wg.Done()

				if progressive, ok := searcher.(*AddonSearcher); ok {
					for batch := range progressive.SearchLinksProgressive(query) {
						if len(batch) > 0 {
							rawBatches <- batch
						}
					}
					return
				}

				if batch := searcher.SearchLinks(query); len(batch) > 0 {
					rawBatches <- batch
				}
			}(searcher)
		}

		wg.Wait()
		close(rawBatches)
	}()

	go func() {
		defer close(updates)
		accumulated := make([]*bittorrent.TorrentFile, 0)

		for batch := range rawBatches {
			batchChan := make(chan *bittorrent.TorrentFile, len(batch))
			for _, torrent := range batch {
				batchChan <- torrent
			}
			close(batchChan)

			resolved := processLinks(xbmcHost, batchChan, SortMovies, true)
			accumulated = mergeProgressiveResults(accumulated, resolved)
			if len(accumulated) > 0 {
				snapshot := append([]*bittorrent.TorrentFile(nil), accumulated...)
				updates <- snapshot
			}
		}
	}()

	return updates
}

// SearchLinksProgressive streams general-search batches from a Python provider.
func (as *AddonSearcher) SearchLinksProgressive(query string) <-chan []*bittorrent.TorrentFile {
	return as.callProgressive("search", as.GetQuerySearchObject(query))
}
