package com.skistation.studentms.config;

import com.skistation.studentms.entities.Student;
import com.skistation.studentms.repository.IStudentRepository;
import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.CommandLineRunner;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
@Slf4j
public class DataInitializer {

    @Bean
    CommandLineRunner initStudentData(IStudentRepository studentRepository) {
        return args -> {
            Student student = new Student();
            student.setFirstName("John");
            student.setAge(25);
            student.setSchool("school");
            studentRepository.save(student);
            log.info("Student data initialized" + student.toString());
        };
    }
}
