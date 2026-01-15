package com.skistation.reservationms.clients;

import com.skistation.reservationms.dto.StudentDTO;
import com.skistation.reservationms.config.FeignOAuth2Config;
import org.springframework.cloud.openfeign.FeignClient;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;

@FeignClient(name = "STUDENTMS", configuration = FeignOAuth2Config.class)
public interface StudentClient {

    @GetMapping("/students/{id}")
    StudentDTO getStudentById(@PathVariable Long id);
}