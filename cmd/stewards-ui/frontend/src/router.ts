import { createRouter, createWebHistory, type RouteRecordRaw } from 'vue-router'

// Lazy-loaded views — keeps the initial bundle small. Nav consolidation
// (feat/lightening, 2026-07-07, .spec/lightening/ui-merge-map.md): 24 routes
// collapsed to 10 primary nav destinations + a dev-tools flyout. Twelve old
// list pages now live as tabs inside three container views (Library, Ledger,
// Steering — each imports the original view components unchanged); their old
// paths redirect into the matching tab so bookmarks never 404. Detail routes
// (/studies/:slug, /councils/:id, /sessions/:sid, /wiki/page/:slug,
// /work-items/:id) stay real routes — they're drill-down targets, not nav.
const Dashboard = () => import('./views/Dashboard.vue')
const Library = () => import('./views/Library.vue')
const Ledger = () => import('./views/Ledger.vue')
const Steering = () => import('./views/Steering.vue')
const StudyDetail = () => import('./views/StudyDetail.vue')
const WorkItems = () => import('./views/WorkItems.vue')
const WorkItemDetail = () => import('./views/WorkItemDetail.vue')
const Sessions = () => import('./views/Sessions.vue')
const NewWork = () => import('./views/NewWork.vue')
const Graph = () => import('./views/Graph.vue')
const CouncilDetail = () => import('./views/CouncilDetail.vue')
const Brainstorm = () => import('./views/Brainstorm.vue')
const Models = () => import('./views/Models.vue')
const Stewdio = () => import('./views/Stewdio.vue')
const WikiReader = () => import('./views/WikiReader.vue')
const NotFound = () => import('./views/NotFound.vue')

const routes: RouteRecordRaw[] = [
  { path: '/',           name: 'dashboard',  component: Dashboard },

  // Container views — tab state lives in the path (/library/:tab) so deep
  // links and refresh keep the tab. The param regex whitelists the tab keys
  // so an unknown tab (e.g. /library/bogus) still falls through to NotFound
  // instead of silently rendering a default. No :tab = the view's default
  // (Library→Studies, Ledger→Watchman per merge map, Steering→Intents).
  { path: '/library/:tab(studies|lessons|search)?', name: 'library', component: Library, props: true, meta: { title: 'Library' } },
  { path: '/ledger/:tab(covenant|watchman|bridge|trust|councils|sabbath)?', name: 'ledger', component: Ledger, props: true, meta: { title: 'Ledger' } },
  { path: '/steering/:tab(intents|projects|scheduled)?', name: 'steering', component: Steering, props: true, meta: { title: 'Steering' } },

  // Old top-level list paths → tab redirects. Query strings are preserved so
  // bookmarks with filters keep working (/studies?kind=doc, /search?q=…) AND
  // so Studies'/Search's own internal router.replace('/studies'|'/search')
  // URL-state writes keep round-tripping through here unchanged.
  { path: '/search',    redirect: (to) => ({ path: '/library/search', query: to.query }) },
  { path: '/studies',   redirect: (to) => ({ path: '/library/studies', query: to.query }) },
  { path: '/lessons',   redirect: (to) => ({ path: '/library/lessons', query: to.query }) },
  { path: '/covenants', redirect: (to) => ({ path: '/ledger/covenant', query: to.query }) },
  { path: '/watchman',  redirect: (to) => ({ path: '/ledger/watchman', query: to.query }) },
  { path: '/bridge',    redirect: (to) => ({ path: '/ledger/bridge', query: to.query }) },
  { path: '/trust',     redirect: (to) => ({ path: '/ledger/trust', query: to.query }) },
  { path: '/councils',  redirect: (to) => ({ path: '/ledger/councils', query: to.query }) },
  { path: '/sabbath',   redirect: (to) => ({ path: '/ledger/sabbath', query: to.query }) },
  { path: '/intents',   redirect: (to) => ({ path: '/steering/intents', query: to.query }) },
  { path: '/projects',  redirect: (to) => ({ path: '/steering/projects', query: to.query }) },
  { path: '/scheduled', redirect: (to) => ({ path: '/steering/scheduled', query: to.query }) },

  // Detail routes — real routes, drill-down targets from the tabs.
  { path: '/studies/:slug', name: 'study-detail', component: StudyDetail, meta: { title: 'Study detail' }, props: true },
  { path: '/councils/:id', name: 'council-detail', component: CouncilDetail, meta: { title: 'Council' }, props: true },
  { path: '/work-items', name: 'work-items', component: WorkItems, meta: { title: 'Work items' } },
  { path: '/work-items/:id', name: 'work-item-detail', component: WorkItemDetail, meta: { title: 'Work item detail' }, props: true },

  // Dev-tools flyout destinations (App.vue "Dev ▾") — out of primary nav but
  // still real routes. /sessions/:sid stays load-bearing (linked from Work
  // item detail + Stewdio).
  { path: '/sessions',   name: 'sessions',   component: Sessions, meta: { title: 'Sessions' } },
  { path: '/sessions/:sid', name: 'session-detail', component: Sessions, meta: { title: 'Session' }, props: true },
  { path: '/brainstorm', name: 'brainstorm', component: Brainstorm, meta: { title: 'Brainstorm' } },

  { path: '/graph',      name: 'graph',      component: Graph, meta: { title: 'Graphs' } },
  { path: '/new',        name: 'new-work',   component: NewWork, meta: { title: 'New work' } },
  { path: '/models',     name: 'models',     component: Models, meta: { title: 'Providers & models' } },
  { path: '/stewdio',    name: 'stewdio',    component: Stewdio, meta: { title: 'Stewdio' } },
  // Wiki reader: /wiki (optionally ?wiki=<slug> to scope the switcher) shows
  // the wikis switcher + page list; /wiki/page/:slug is a single page (the
  // route wiki-links resolve to — see useWikiLinks in WikiReader.vue). Kept as
  // two static routes rather than one `/wiki/:slug?` so "page" never collides
  // with a wiki's own slug.
  { path: '/wiki',           name: 'wiki',      component: WikiReader, meta: { title: 'Wiki' } },
  { path: '/wiki/page/:slug', name: 'wiki-page', component: WikiReader, props: true, meta: { title: 'Wiki page' } },
  // Catch-all — an unknown URL rendered a silent blank RouterView before this.
  { path: '/:pathMatch(.*)*', name: 'not-found', component: NotFound, meta: { title: 'Not found' } },
]

export default createRouter({
  history: createWebHistory(),
  routes,
})
