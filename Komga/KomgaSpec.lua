return {
    base_url = "http://192.168.1.18:10102",
    name = "KomgaAPI",
    version = "0.2",
    headers = {
        ["X-API-Key"] = "451e132996b44937b1576242447d9cd2"
    },
    methods = {
        komgaLogin = {
            path = "/api/v2/users/me",
            method = "GET",
            expected_status = {200}
        },
        getUserConfig = {
            path = "/api/v2/users/me",
            method = "GET",
            expected_status = {200}
        },
        getChapterList = {
            path = "/api/v1/books/list",
            method = "POST",
            optional_params = {"condition","size"},
            payload = {"condition"},
            expected_status = {200}
        },
        getBookShelf = {
            path = "/api/v1/series/list",
            method = "POST",
            required_params = {"fullTextSearch"},
            optional_params = {"size"},
            payload = {"fullTextSearch"},
            expected_status = {200}
        },
        getShelfBook = {
            path = "/api/v1/libraries",
            method = "GET",
            expected_status = {200}
        },
        getBookContent = {
            path = "/api/v1/books/:bookId/pages/:pageNumber",
            method = "GET",
            required_params = {"bookId", "pageNumber"},
            expected_status = {200}
        },
        saveBookProgress = {
            path = "/api/v1/books/:bookId/read-progress",
            method = "PATCH",
            required_params = {"bookId"},
            optional_params = {"completed","page"},
            payload = {"completed","page"},
            expected_status = {204}
        },
        getBookProgression = {
            path = "/api/v1/books/:bookId/progression",
            method = "GET",
            required_params = {"bookId"},
            expected_status = {200}
        },
        updateBookProgression = {
            path = "/api/v1/books/:bookId/progression",
            method = "PUT",
            required_params = {"bookId"},
            optional_params = {"modified","device","locator"},
            payload = {"modified","device","locator"},
            expected_status = {204}
        },
        getBookPositions = {
            path = "/api/v1/books/:bookId/positions",
            method = "GET",
            required_params = {"bookId"},
            expected_status = {200}
        },
         getEpubManifest = {
             path = "/api/v1/books/:bookId/manifest/epub",
             method = "GET",
             required_params = {"bookId"},
             expected_status = {200}
         },
        searchBookSource = {
            path = "/searchBookSource",
            method = "GET",
            required_params = {"url", "bookSourceGroup"},
            optional_params = {"v", "searchSize", "lastIndex"},
            expected_status = {200}
        },
        searchBookMulti = {
            path = "/searchBookMulti",
            method = "GET",
            required_params = {"v", "key", "bookSourceGroup", "concurrentCount", "lastIndex"},
            optional_params = {"searchSize", "bookSourceUrl"},
            expected_status = {200}
        },
        getBookSources = {
            path = "/getBookSources",
            method = "GET",
            required_params = {"v", "simple"},
            expected_status = {200}
        },
        searchBook = {
            path = "/searchBook",
            method = "GET",
            required_params = {"v", "key", "bookSourceUrl", "bookSourceGroup", "concurrentCount", "lastIndex", "page"},
            expected_status = {200}
        },
        getChapterInfo = {
            path = "/api/v1/books/:bookId",
            method = "GET",
            required_params = {"bookId"},
            expected_status = {200}
        },
        saveBook = {
            path = "/saveBook",
            method = "POST",
            required_params = {"name", "author", "bookUrl", "origin", "originName", "originOrder"},
            optional_params = {"v", "durChapterIndex", "durChapterPos", "durChapterTime", "durChapterTitle",
                               "wordCount", "intro", "totalChapterNum", "kind", "type"},
            payload = {"name", "author", "bookUrl", "origin", "originName", "originOrder", "durChapterIndex",
                       "durChapterPos", "durChapterTime", "durChapterTitle", "wordCount", "intro", "totalChapterNum",
                       "kind", "type"},
            unattended_params = true,
            expected_status = {200}
        },
        deleteBook = {
            path = "/deleteBook",
            method = "POST",
            required_params = {"name", "author", "bookUrl", "origin", "originName", "originOrder"},
            optional_params = {"v", "durChapterIndex", "durChapterPos", "durChapterTime", "durChapterTitle",
                               "wordCount", "intro", "totalChapterNum", "kind", "type"},
            payload = {"name", "author", "bookUrl", "origin", "originName", "originOrder", "durChapterIndex",
                       "durChapterPos", "durChapterTime", "durChapterTitle", "wordCount", "intro", "totalChapterNum",
                       "kind", "type"},
            unattended_params = true,
            expected_status = {200}
        },
        getTxtTocRules = {
            path = "/getTxtTocRules",
            method = "GET",
            required_params = {"v"},
            expected_status = {200}
        },
        getReplaceRules ={
            path = "/getReplaceRules",
            method = "GET",
            required_params = {"v"},
            expected_status = {200}
        },
        getSystemInfo = {
            path = "/getSystemInfo",
            method = "GET",
            required_params = {"v"},
            expected_status = {200}
        },
        getCover = {
            path = "/getCover",
            method = "GET",
            expected_status = {200}
        },
        refreshToc = {
            path = "/refreshToc",
            method = "POST",
            required_params = {"url"},
            payload = {"url"},
            optional_params = {"v"},
            expected_status = {200}
        }
    }
}
