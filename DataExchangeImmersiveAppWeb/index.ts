import index from "./index.html";

const isProduction = process.env.NODE_ENV === "production";

const server = Bun.serve({
  routes: {
    "/": index,
  },
  development: isProduction
    ? false
    : {
        hmr: true,
        console: true,
      },
});

console.log(`Listening on ${server.url}`);
