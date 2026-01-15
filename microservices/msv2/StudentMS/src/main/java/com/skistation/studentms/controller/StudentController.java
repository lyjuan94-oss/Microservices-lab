package com.skistation.studentms.controller;

import com.skistation.studentms.entities.Student;
import com.skistation.studentms.repository.IStudentRepository;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

@RestController
@RequestMapping(path = "/students")
public class StudentController {

    @Autowired
    private IStudentRepository studentRepository;

    @GetMapping("/test")
    public String test() {
        return "test";
    }

    // Create
    @PostMapping
    public ResponseEntity<Student> createStudent(@RequestBody Student student) {
        Student saved = studentRepository.save(student);
        return new ResponseEntity<>(saved, HttpStatus.CREATED);
    }

    // Read all
    @GetMapping("/students")
    public List<Student> getAllStudents() {
        List<Student> list = new ArrayList<>();
        studentRepository.findAll().forEach(list::add);
        return list;
    }

    // Read by id
    @GetMapping("/{id}")
    public ResponseEntity<Student> getStudentById(@PathVariable Long id) {
        Optional<Student> s = studentRepository.findById(id);
        return s.map(ResponseEntity::ok).orElseGet(() -> ResponseEntity.notFound().build());
    }

    // Update
    @PutMapping("/{id}")
    public ResponseEntity<Student> updateStudent(@PathVariable Long id, @RequestBody Student student) {
        Optional<Student> existing = studentRepository.findById(id);
        if (existing.isEmpty()) {
            return ResponseEntity.notFound().build();
        }
        Student toUpdate = existing.get();
        toUpdate.setFirstName(student.getFirstName());
        toUpdate.setSchool(student.getSchool());
        toUpdate.setAge(student.getAge());
        toUpdate.setInc(student.getInc());
        Student saved = studentRepository.save(toUpdate);
        return ResponseEntity.ok(saved);
    }

    // Delete
    @DeleteMapping("/{id}")
    public ResponseEntity<Void> deleteStudent(@PathVariable Long id) {
        Optional<Student> existing = studentRepository.findById(id);
        if (existing.isEmpty()) {
            return ResponseEntity.notFound().build();
        }
        studentRepository.deleteById(id);
        return ResponseEntity.noContent().build();
    }
}

