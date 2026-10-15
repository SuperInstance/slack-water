/**
 * A path-pattern router just small enough for this worker — plain fetch
 * routing with no framework dependency, so the deploy bundle stays tiny and
 * there is nothing between the request and the D1 calls worth auditing.
 */

export type RouteParams = Record<string, string>;

export interface RouteContext<Env> {
	req: Request;
	params: RouteParams;
	env: Env;
	ctx: ExecutionContext;
}

export type Handler<Env> = (context: RouteContext<Env>) => Promise<Response>;

interface Route<Env> {
	method: string;
	segments: string[];
	handler: Handler<Env>;
}

export class Router<Env> {
	private routes: Route<Env>[] = [];

	public add(method: string, pattern: string, handler: Handler<Env>): this {
		this.routes.push({
			method,
			segments: pattern.split("/").filter((s) => s !== ""),
			handler,
		});
		return this;
	}

	public async handle(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
		const url = new URL(req.url);
		const path = url.pathname;
		const pathSegments = path.split("/").filter((s) => s !== "");

		let pathMatched = false;
		for (const route of this.routes) {
			const params = matchSegments(route.segments, pathSegments);
			if (params === null) continue;
			pathMatched = true;
			if (route.method !== req.method) continue;
			return route.handler({ req, params, env, ctx });
		}

		return jsonResponse(
			pathMatched ? 405 : 404,
			pathMatched
				? { ok: false, error: "method not allowed" }
				: { ok: false, error: "not found" },
		);
	}
}

function matchSegments(
	routeSegments: string[],
	pathSegments: string[],
): RouteParams | null {
	if (routeSegments.length !== pathSegments.length) return null;
	const params: RouteParams = {};
	for (let i = 0; i < routeSegments.length; i++) {
		const route = routeSegments[i]!;
		const actual = pathSegments[i]!;
		if (route.startsWith(":")) {
			params[route.slice(1)] = decodeURIComponent(actual);
		} else if (route !== actual) {
			return null;
		}
	}
	return params;
}

export function jsonResponse(status: number, body: unknown): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: {
			"content-type": "application/json; charset=utf-8",
			"cache-control": "no-store",
		},
	});
}
