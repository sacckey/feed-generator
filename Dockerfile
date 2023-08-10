FROM node:20-alpine

WORKDIR /app
COPY ./package.json ./yarn.lock ./
RUN yarn install --production --frozen-lockfile > /dev/null

COPY ./src ./

EXPOSE 3000
ENV NODE_ENV=production

CMD ["yarn", "start"]
