function read(name: string): string {
  return (process.env[name] ?? "").trim();
}

export const serverEnv = {
  get mongoUri() {
    return read("MONGO_URI");
  },
  get mongoDatabase() {
    return read("MONGO_DB_NAME") || "violet";
  },
  get relationshipsPath() {
    return read("MONGO_RELATIONSHIPS_PATH") || "relationships";
  },
  get logsPath() {
    return read("MONGO_LOGS_PATH") || "logs";
  },
  get googleClientId() {
    return read("GOOGLE_CLIENT_ID");
  },
  get mongoError(): string | null {
    if (!this.mongoUri) return "MONGO_URI is not configured.";
    if (!/^mongodb(\+srv)?:\/\//i.test(this.mongoUri)) return "MONGO_URI is not a valid MongoDB URI.";
    return null;
  },
};
