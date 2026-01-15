FROM eclipse-temurin:21-jdk-alpine
WORKDIR /app

# Expect a pre-built jar in target/ (build it on the host with ./mvnw package -DskipTests)
ARG JAR_FILE=target/*.jar
COPY ${JAR_FILE} app.jar
EXPOSE 8086
ENTRYPOINT ["java", "-jar", "app.jar"]
